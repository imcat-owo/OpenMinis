import Foundation

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Block Summary Generation (nested mode)
//
// [T-nested-summary] After a turn completes (thinking closed + all tool
// results in), the collapsed thinking/tool rows show a NATURAL one-sentence
// summary of what was actually done — e.g. "查了北京明天的天气并存进了记忆",
// not "使用了2个工具".
//
// Flow:
//   1. `generateBlockSummariesIfNeeded()` runs when the agent loop ends
//      (isProcessing true→false). It finds assistant messages whose
//      thinking/tool blocks still lack a summary.
//   2. While the turn is in progress, rows show a working state ("思考中…"
//      / tool name) — `summary` stays nil.
//   3. A lightweight hidden LLM call (sub-model, thinking off, invisible in
//      chat) generates ONE sentence in the user's language from the thinking
//      text + tool records. Only the sentence is stored on `block.summary`.
//   4. If generation fails, a metadata fallback assembles "verb + key param"
//      phrases per tool type — never a bare count.

extension AIChatViewModel {

    /// Call when the agent loop finishes. Generates natural one-sentence
    /// summaries for thinking blocks of turns that don't have one yet.
    func generateBlockSummariesIfNeeded() {
        // Find thinking blocks lacking summaries in recent assistant messages.
        // Only the last few messages — older turns were already handled.
        let candidates: [(message: ChatMessage, block: AssistantBlock)] = messages
            .suffix(5)
            .filter { $0.role == .assistant }
            .flatMap { msg in
                msg.blocks
                    .filter { $0.kind == .thinking && $0.summary == nil }
                    .map { (msg, $0) }
            }
        guard !candidates.isEmpty else { return }

        for (message, thinkingBlock) in candidates {
            // Skip turns still in progress (a tool is still running).
            let toolsInTurn = message.blocks.filter { $0.kind.isToolKind }
            let anyRunning = toolsInTurn.contains {
                if case .running = $0.toolStatus { return true }
                if case .streaming = $0.toolStatus { return true }
                return false
            }
            if anyRunning { continue }

            // Snapshot the data the generator needs (blocks are live objects;
            // capture values now so the Task doesn't race the next turn).
            let thinkingText = thinkingBlock.content
            let toolRecords: [(name: String, args: String, result: String, status: String)] =
                toolsInTurn.map { tool in
                    let name = tool.toolDescription
                    let args = tool.toolInputArgs ?? ""
                    let result = String(tool.content.prefix(400))
                    let status: String
                    switch tool.toolStatus {
                    case .success: status = "success"
                    case .failed(let m): status = "failed: \(m)"
                    case .cancelled: status = "cancelled"
                    default: status = "done"
                    }
                    return (name, args, result, status)
                }

            Task { [weak self, weak thinkingBlock] in
                guard let self else { return }
                let summary = await self.generateTurnSummaryWithEntry(
                    thinkingText: thinkingText,
                    tools: toolRecords
                ) ?? Self.fallbackTurnSummary(tools: toolRecords)
                await MainActor.run {
                    thinkingBlock?.summary = summary
                }
            }
        }
    }

    // MARK: - Hidden LLM call

    /// Instance wrapper that resolves the sub-model entry, then runs the
    /// hidden call. Returns nil on any failure (caller falls back).
    private func generateTurnSummaryWithEntry(
        thinkingText: String,
        tools: [(name: String, args: String, result: String, status: String)]
    ) async -> String? {
        let hasThinking = !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasThinking || !tools.isEmpty else { return nil }
        guard let subEntry = resolveSubEntry() else {
            logger.info("[BlockSummary] No sub model available — using fallback")
            return nil
        }

        let langInjection = Self.summaryLanguageInjection()

        let toolsDesc: String = tools.isEmpty ? "(no tool calls)" : tools.map { t in
            let argsPreview = t.args.isEmpty ? "" : " args=\(String(t.args.prefix(150)))"
            let resultPreview = t.result.isEmpty ? "" : " result=\(String(t.result.prefix(200)))"
            return "- \(t.name) [\(t.status)]\(argsPreview)\(resultPreview)"
        }.joined(separator: "\n")

        let prompt = """
        Summarize what the AI accomplished in this turn in ONE natural sentence.
        \(langInjection)
        Rules:
        - Output ONLY the sentence, no quotes, no preamble, no bullet points.
        - Describe the OUTCOME (what got done), not the process.
        - One sentence, under 40 words.
        - Never write things like "used 2 tools" — say what was actually achieved.

        The AI's thinking (truncated):
        \(String(thinkingText.prefix(1500)))

        Tool calls this turn:
        \(toolsDesc)
        """

        do {
            let provider = await Self.makeAgentProvider(for: subEntry)
            let stream = try await provider.streamAgentMessage(
                messages: [AgentMessage(role: .user, parts: [.text(prompt)])],
                systemPrompt: "You summarize what an AI accomplished in one natural sentence. Output ONLY the sentence, nothing else.",
                tools: [],
                maxTokens: 256,
                thinkingLevel: .off
            )
            var responseText = ""
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    responseText += delta
                case .done:
                    break
                default:
                    break
                }
            }
            let trimmed = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !trimmed.isEmpty else { return nil }
            // One sentence: cut at the first sentence boundary if the model
            // got chatty, keep it tight.
            let sentence = Self.firstSentence(of: trimmed)
            logger.info("[BlockSummary] Generated: \(sentence.prefix(60))")
            return sentence
        } catch {
            logger.info("[BlockSummary] LLM call failed (\(error.localizedDescription)) — using fallback")
            return nil
        }
    }

    /// Keep only the first sentence (up to . ! ? 。！？).
    private static func firstSentence(of text: String) -> String {
        let terminators: [Character] = [".", "!", "?", "。", "！", "？"]
        for (i, ch) in text.enumerated() {
            if terminators.contains(ch) {
                let idx = text.index(text.startIndex, offsetBy: i + 1)
                return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// User's interface language, so the summary matches the UI language.
    private static func summaryLanguageInjection() -> String {
        let userSelected = (UserDefaults.standard.string(forKey: "appLanguage") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let preferred: String = !userSelected.isEmpty
            ? userSelected
            : (Bundle.main.preferredLocalizations.first
               ?? Locale.current.language.languageCode?.identifier
               ?? "en")
        return """
        The user's app interface language is "\(preferred)". Write the summary in this language.
        用户的 App 界面语言是 "\(preferred)"，请用该语言写这句总结。
        """
    }

    // MARK: - Metadata fallback

    /// Assembles a human-readable summary from tool metadata when the LLM
    /// call fails. Verb + key parameter per tool type — never a bare count.
    static func fallbackTurnSummary(
        tools: [(name: String, args: String, result: String, status: String)]
    ) -> String {
        guard !tools.isEmpty else { return "完成了思考" }
        let phrases = tools.prefix(3).map { verbPhrase(name: $0.name, args: $0.args) }
        return phrases.joined(separator: "，")
    }

    /// Human-readable "verb + key param" for one tool. Chinese-first (the
    /// user's language); the LLM path handles other languages.
    private static func verbPhrase(name: String, args: String) -> String {
        // Extract a filename-ish key param from args JSON when present.
        let keyParam: String = {
            guard let data = args.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "" }
            for key in ["path", "file", "filename", "command", "url", "action", "query"] {
                if let v = obj[key] as? String, !v.isEmpty {
                    // Filenames only — full paths get long.
                    let short = (v as NSString).lastPathComponent
                    return String(short.prefix(40))
                }
            }
            return ""
        }()

        let lower = name.lowercased()
        func withParam(_ verb: String) -> String {
            keyParam.isEmpty ? verb : "\(verb)\(keyParam)"
        }

        if lower.contains("read") || lower.contains("读取") { return withParam("读取了") }
        if lower.contains("write") || lower.contains("写入") { return withParam("写入了") }
        if lower.contains("edit") || lower.contains("修改") { return withParam("修改了") }
        if lower.contains("shell") || lower.contains("command") || lower.contains("执行") {
            return withParam("执行了命令")
        }
        if lower.contains("browser") || lower.contains("浏览") { return withParam("浏览了网页") }
        if lower.contains("image") || lower.contains("图片") { return withParam("查看了图片") }
        if lower.contains("memory") || lower.contains("记忆") { return withParam("更新了记忆") }
        if lower.contains("ask") || lower.contains("提问") { return "向用户提问" }
        // Generic: use the tool's display name as the verb phrase.
        return keyParam.isEmpty ? name : "\(name)：\(keyParam)"
    }
}
