import SwiftUI
import Combine

// MARK: - Assistant Block View (individual block — isolated invalidation)

/// [T-nested-ui] Uniform inline height for ALL nested blocks — thinking
/// drawers, thinking summary rows, and tool summary rows. Fixed so the chat
/// never reflows as content streams; overflow scrolls inside the drawer.
/// The chat itself never floods.
extension AssistantBlockView {
    static let nestedInlineHeight: CGFloat = 100
}

/// [T-nested-ui] Drawer background: the user's customizable thinking-card
/// image (Settings → Appearance → thinking card), aspect-fill, clipped to
/// the drawer's rounded shape, at the user's chosen opacity. Falls back to
/// the theme surface token when no custom image is set. Applied to inline
/// drawers AND pushed detail pages — the image follows the content.
///
/// [T-theme-no-hardcode] Corner radius comes from the theme pack
/// (`thinkingRadius` via `radius(.thinking)`); the fallback fill is the
/// theme surface token. Nothing is hardcoded.
struct NestedDrawerBackground: ViewModifier {
    var cornerRadius: CGFloat? = nil

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? MinisThemeShape.pack.radius(.thinking)
        content
            .background {
                if let uiImage = MinisThemeShape.pack.thinkingCardImage() {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(MinisThemeShape.pack.thinkingCardImageOpacity)
                } else {
                    ChatColors.secondaryBg
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    /// [T-nested-ui] Applies the thinking-card background (custom image or
    /// theme fallback) clipped to the theme's thinking corner radius.
    func nestedDrawerBackground(cornerRadius: CGFloat? = nil) -> some View {
        modifier(NestedDrawerBackground(cornerRadius: cornerRadius))
    }
}

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-minis-tts] Selection-menu read-aloud hooks, plumbed
    /// down to SelectableMarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    /// [T-message-action-bar 09-11] Pause/resume/stop for the bubble action
    /// bar. nil hides the bar (streaming reply, or a bridge without a VM).
    var speechController: (any SpeechControlling)?
    /// [T-action-bar-play-bubble 09-13] 醒醒 5: when this reply carries a
    /// wx-style voice bubble (AI Voice Replies), the action bar's Play button
    /// replays THE BUBBLE'S OWN AUDIO FILE (already synthesized with the
    /// configured voice) instead of re-synthesizing the text through TTS.
    /// Pause/resume/continue then ride the GlobalAudioPlayer like any media.
    /// nil (or a text-only reply) keeps the old behavior: speak the text.
    var voiceBubbleFileURL: URL?
    /// [T-action-bar 09-11] Regenerate this assistant message.
    var onRegenerate: (() -> Void)?
    /// [T-action-bar 09-11] Delete this single assistant message.
    var onDeleteMessage: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }
    /// The action bar belongs to completed assistant replies only. A cell can
    /// receive speech hooks while it represents a user/system row during reuse;
    /// requiring both actions prevents controls from appearing on non-AI content.
    private var canShowActionBar: Bool {
        message.role == .assistant && onRegenerate != nil && onDeleteMessage != nil
    }

    var body: some View {
        switch block.kind {
        case .text:
            if !block.content.isEmpty {
                // [T-bubble-blank-line-split] Split the block's markdown into
                // blank-line-separated paragraphs, each rendered as its own
                // bubble (WeChat-style: several utterances → several bubbles).
                // Splitting is RENDER-ONLY — block.content, persistence and
                // the LLM-facing history all stay one block.
                //
                // Fence/table guard: content containing a code fence or a
                // markdown table is NOT split. Blank lines inside those
                // constructs are structural, and naive splitting would shred
                // them; such blocks keep the single wide-bubble look.
                let segments = Self.splitBubbleSegments(block.content)
                if segments.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            self.singleTextBubble(seg)
                        }
                        // [T-message-action-bar 09-11] One action bar under the
                        // LAST bubble group of the last text block — the reply's
                        // visible tail. It reads THE WHOLE BLOCK (all segments),
                        // not just the last segment, so "播放本条" means this
                        // message's complete text.
                        if Self.isLastTextBlock(of: message, block: block),
                           canShowActionBar {
                            actionBar(forBlockContent: block.content)
                        }
                    }
                    .id(appearanceStudio.themePackRevision)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        self.singleTextBubble(block.content)
                        if Self.isLastTextBlock(of: message, block: block),
                           canShowActionBar {
                            actionBar(forBlockContent: block.content)
                        }
                    }
                    .id(appearanceStudio.themePackRevision)
                }
            }
        case .thinking:
            // [T-nested-ui] Nested mode: pure thinking (no tools after this
            // block) shows the fixed-height content drawer; once tools are
            // called, thinking collapses to a summary row (tap pushes the
            // detail page). hasToolsAfter is computed from the message's
            // block order — the single source of truth for the transition.
            let idx = message.blocks.firstIndex(where: { $0.id == block.id })
            let hasToolsAfter: Bool = {
                guard let idx else { return false }
                return message.blocks[(idx + 1)...].contains { $0.kind.isToolKind }
            }()
            ThinkingBlockView(
                block: block,
                isStreaming: isActiveMessage && message.blocks.last?.id == block.id,
                hasToolsAfter: hasToolsAfter,
                onOpenDetail: { detailBlock = block }
            )
            .padding(.vertical, 2)
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool, .askUserTool:
            // [chat-ui] One unified tool case — icon + browserPool plumbed from
            // the shared helpers above. Identical behavior to the eight
            // per-kind cases this replaces (only shell/browser got browserPool).
            ToolCapsuleView(block: block, icon: Self.toolCapsuleIcon(for: block.kind), accentColor: ChatColors.accent,
                            commandStartTime: commandStartTime, onStop: onStop,
                            browserPool: Self.toolCapsuleNeedsBrowserPool(for: block.kind) ? browserPool : nil,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock)
        case .info:
            let allLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Separate reason lines (⚠️) from the final switched line (✅)
            let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
            let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
            // Truncate middle if more than 9 reason lines
            let displayReasons: [String] = {
                if reasonLines.count <= 9 { return reasonLines }
                return Array(reasonLines.prefix(4)) + [AppLocalized("⋯ \(reasonLines.count - 8) more")] + Array(reasonLines.suffix(4))
            }()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(displayReasons.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ChatColors.warning.opacity(0.8))
                        Text(switchedLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ChatColors.warning.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatColors.warning.opacity(0.14), lineWidth: 0.5))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.content
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private func singleTextBubble(_ content: String) -> some View {
        textBlockView(markdown: content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                MinisThemeShape.assistantBubble.fill(ChatColors.assistantBubble)
            )
            .overlay(
                MinisThemeShape.assistantBubble.fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
            )
            .clipShape(MinisThemeShape.assistantBubble)
    }

    // MARK: - [T-message-action-bar 09-11] kelivo-style bubble actions

    /// True when this block is the message's LAST text block (the action bar
    /// only hangs there — earlier text blocks read as part of the flow).
    /// [chat-ui] SF Symbol per tool kind — single source of truth shared by the
    /// per-block switch below and the tool-group folding card.
    static func toolCapsuleIcon(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return "terminal"
        case .fileReadTool: return "doc.text"
        case .fileWriteTool: return "doc.text.fill"
        case .fileEditTool: return "square.and.pencil"
        case .browserTool: return "globe"
        case .readImageTool: return "photo"
        case .memoryTool: return "brain.head.profile"
        case .askUserTool: return "questionmark.circle"
        case .text, .thinking, .info: return "wrench.and.screwdriver"
        }
    }

    /// [chat-ui] Which tool kinds need the live browser tab pool plumbed into
    /// their capsule (mirrors the per-kind call sites below).
    static func toolCapsuleNeedsBrowserPool(for kind: AssistantBlockKind) -> Bool {
        switch kind {
        case .shellTool, .browserTool: return true
        default: return false
        }
    }

    static func isLastTextBlock(of message: ChatMessage, block: AssistantBlock) -> Bool {
        let textBlocks = message.blocks.filter { if case .text = $0.kind { return true }; return false }
        guard let last = textBlocks.last else { return false }
        return last.id == block.id
    }

    /// The kelivo-style action row (copy / play-pause / stop). Uses the
    /// selection-TTS hook (`onSpeakText`) so the bubble speaks through the
    /// service-layer voice; the vm doubles as the SpeechControlling for
    /// pause/resume/stop. Nil hooks (streaming / bridging gaps) hide the bar.
    @ViewBuilder
    private func actionBar(forBlockContent content: String) -> some View {
        if let onSpeakText, let controller = speechController {
            // [T-action-bar-play-bubble 09-13] Reply with a voice bubble →
            // Play replays the bubble's audio file (its synthesized audio IS
            // this reply's voice form; re-synthesizing the text would produce
            // a second, differently-timed take and waste a vendor call).
            if let fileURL = voiceBubbleFileURL {
                BubbleAudioActionBar(fileURL: fileURL,
                                     onRegenerate: { onRegenerate?() },
                                     onDelete: { onDeleteMessage?() },
                                     speakText: content,
                                     onSpeak: onSpeakText)
            } else {
                MessageActionBar(
                    speakText: content,
                    onSpeak: onSpeakText,
                    controller: controller,
                    onRegenerate: { onRegenerate?() },
                    onDelete: { onDeleteMessage?() }
                )
            }
        }
    }

    /// Split assistant markdown into bubble segments on blank lines.
    /// Empty when the content should stay one bubble (no blank lines, or
    /// structural markdown that must not be shredded).
    static func splitBubbleSegments(_ content: String) -> [String] {
        // Guard: code fences / tables render wrong when split — keep whole.
        if content.contains("```") || content.contains("\n|") || content.hasPrefix("|") {
            return [content]
        }
        // Split on 2+ consecutive newlines (blank line), collapsing runs.
        let raw = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard raw.count > 1 else { return [content] }
        // Guard 2: a blank line INSIDE a list (indented continuation) splits
        // the list mid-structure; if any segment starts with list markup and
        // another continues it, don't shred. Cheap heuristic: if >1 segment
        // starts with a list marker, treat the whole block as list content.
        let listStarts = raw.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("1. ") }
        if listStarts.count > 1 { return [content] }
        return raw
    }

    @ViewBuilder
    private func textBlockView(markdown: String) -> some View {
        SelectableMarkdownView(
            markdown: markdown,
            cachedContent: markdown == block.content ? block.cachedMarkdown : nil,
            cachedAttributedString: markdown == block.content ? block.cachedAttributedString : nil,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MinisOpenURLHandler())
    }

    @ViewBuilder
    private var textBlockView: some View {
        textBlockView(markdown: block.content)
    }
}

// MARK: - Shimmer Overlay (continuous diagonal shine via offset animation)

/// A diagonal shimmer band that sweeps from top-leading to bottom-trailing.
/// Uses a single stable gradient with an animated offset rather than rebuilding
/// gradient stops every frame — avoids a CAGradientLayer colorspace teardown
/// race during CATransaction flush (EXC_BAD_ACCESS at encode_colorspace).
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var offsetX: CGFloat = -1.0

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    private func bell(_ x: CGFloat) -> CGFloat {
        exp(-4.5 * x * x)
    }

    private var stableStops: [Gradient.Stop] {
        let stepCount = 12
        let bandRadius: CGFloat = 0.40
        let center: CGFloat = 0.5
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: .white.opacity(0), location: 0))
        for i in 0...stepCount {
            let frac = CGFloat(i) / CGFloat(stepCount)
            let pos = center - bandRadius + frac * bandRadius * 2.0
            let dist = (pos - center) / bandRadius
            let alpha = bell(dist) * peakOpacity
            stops.append(.init(color: .white.opacity(Double(alpha)), location: pos))
        }
        stops.append(.init(color: .white.opacity(0), location: 1))
        return stops
    }

    var body: some View {
        GeometryReader { geo in
            let diag = geo.size.width + geo.size.height
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: stableStops,
                        startPoint: UnitPoint(x: 0, y: 1),
                        endPoint: UnitPoint(x: 1, y: 0)
                    )
                )
                .frame(width: diag, height: geo.size.height)
                .offset(x: offsetX * geo.size.width)
                .onAppear {
                    withAnimation(
                        .linear(duration: 2.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        offsetX = 1.0
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Tool Capsule View (unified pill for all tool types)

struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let icon: String
    let accentColor: Color
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var detailBlock: AssistantBlock?
    @State private var dotsActive = false
    /// [T-tool-bg-suspended-hint] Drives the background-suspension info alert.
    @State private var showBgHintAlert = false
    /// [T-ios-memory-write-revoke] Confirmation + result alerts for undoing a
    /// memory_write straight from the tool capsule's long-press menu.
    @State private var showRevokeMemoryAlert = false
    @State private var revokeMemoryResult: String?
    @State private var showRevokeMemoryResultAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    /// Show the yellow ⓘ hint only when this tool was flagged as background-
    /// suspended AND enhanced background isn't already effective (nothing to
    /// suggest if it's on). Mirrors the BackgroundInterruptionTracker gate.
    private var showBgSuspendedHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// [T-ios-retry-hide-when-processing] Used to suppress the "Re-run From
    /// Here" long-press menu item while the agent loop is busy — tapping it
    /// mid-run would corrupt the in-flight processing state.
    @EnvironmentObject private var vm: AIChatViewModel

    /// [T-ios-memory-write-revoke] Whether this block is a `memory_write` that
    /// carries input args at all — the cheap check that decides whether the Undo
    /// menu item is offered. Deliberately does NOT parse the JSON: this feeds
    /// `ToolMenuKey`, which is rebuilt on every eager body pass, and re-running
    /// `JSONSerialization` there is exactly the per-frame work the menu gate
    /// exists to avoid. Other tools and `memory_get` never match.
    private var isRevocableMemoryWrite: Bool {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return false }
        guard let args = block.toolInputArgs else { return false }
        return !args.isEmpty
    }

    /// The text this block wrote to memory. Parsed lazily — only when the menu
    /// item is actually tapped — same treatment as `toolDetailsClipboard`.
    /// Nil when the args carry no non-empty `content` (e.g. a malformed or
    /// still-streaming tool call), which the confirm action treats as a no-op.
    private var memoryWriteContent: String? {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return nil }
        return MemoryWriteRevoker.writtenContent(fromToolInputArgs: block.toolInputArgs)
    }

    /// Display text: prefer LLM-generated toolSummary, fall back to toolDescription.
    private var displayText: String {
        if let summary = block.toolSummary, !summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// [T-ios-tool-bubble-longpress-menu] Human-readable, paste-back-able
    /// dump of this tool call + its result for the "Copy Tool Details"
    /// menu action. Pulls tool name from the block kind, the input JSON
    /// from toolInputArgs (pretty-printed when it parses), and the result
    /// text + status from the block's content / toolStatus (with the
    /// snapshot text as a fallback source).
    private var toolDetailsClipboard: String {
        // Tool name from the block kind.
        let toolName: String
        switch block.kind {
        case .shellTool:     toolName = "shell_execute"
        case .fileReadTool:  toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool:  toolName = "file_edit"
        case .browserTool:   toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool:    toolName = "memory"
        case .askUserTool:   toolName = "ask_user_input_v0"
        case .text, .thinking, .info: toolName = "unknown"
        }

        // Pretty-print the input JSON when possible; otherwise emit raw.
        let inputBlock: String
        if let raw = block.toolInputArgs, !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: pretty, encoding: .utf8) {
                inputBlock = prettyStr
            } else {
                inputBlock = raw
            }
        } else {
            inputBlock = "(no input captured)"
        }

        // Result text: prefer the live block content, fall back to the
        // snapshot text matched by toolUseId.
        var resultText = block.content
        if resultText.isEmpty, let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        // Status string.
        let statusStr: String
        switch block.toolStatus {
        case .success:   statusStr = "success"
        case .failed:    statusStr = "failed"
        case .cancelled: statusStr = "cancelled"
        case .running:   statusStr = "running"
        case .streaming: statusStr = "streaming"
        case .none:      statusStr = "unknown"
        }

        var resultMeta = "(\(resultText.count) chars, \(statusStr)"
        if hasScreenshot { resultMeta += ", screenshot" }
        resultMeta += ")"

        return """
        ## Tool Call
        name: \(toolName)
        id: \(block.toolUseId ?? "(none)")
        input:
        \(inputBlock)

        ## Tool Result
        \(resultMeta)
        \(resultText)
        """
    }

    private var isStreaming: Bool {
        if case .streaming = block.toolStatus { return true }
        return false
    }

    var body: some View {
        HStack {
            // [T-nested-ui] Minimal tool row at the uniform inline height.
            // Tapping pushes the detail page (nested mode, not a sheet).
            Button {
                detailBlock = block
            } label: {
                HStack(spacing: 8) {
                    // Tool-type icon, gray like Claude.
                    statusOrIcon

                    // Description text with bouncing dots during streaming
                    // [T-theme-no-hardcode] Font size from the theme pack.
                    HStack(spacing: 0) {
                        Text(displayText)
                            .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                            .foregroundStyle(ChatColors.secondaryText)
                            .lineLimit(1)
                        if isStreaming {
                            ForEach(0..<3, id: \.self) { i in
                                Text(".")
                                    .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .offset(y: dotsActive ? -2 : 1)
                                    .animation(
                                        .easeInOut(duration: 0.35)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.12),
                                        value: dotsActive
                                    )
                            }
                        }
                    }
                    .lineLimit(1)

                    // Execution duration (shown after completion).
                    // [T-theme-no-hardcode] Font size from the theme pack.
                    if let dur = durationText {
                        Text(dur)
                            .font(.system(size: MinisThemeShape.thinkingBodySize, weight: .regular, design: .monospaced))
                            .foregroundStyle(ChatColors.tertiaryText)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                .padding(.horizontal, 12)
                .frame(height: AssistantBlockView.nestedInlineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .nestedDrawerBackground()
            .contextMenu {
                // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                // tree behind an Equatable key so this tool cell's body churn
                // during `gh`/shell streaming doesn't rebuild + re-diff the menu
                // subtree every frame (part of the deep ContextMenuModifier
                // recursion in incident 98E8805F). `toolDetailsClipboard` is read
                // lazily at TAP time, so the key only tracks structure: the tool
                // (blockId), whether the Re-run branch is shown (isProcessing),
                // and whether the memory-Undo branch is shown. All three are
                // cheap reads — the expensive payloads (clipboard dump, written
                // memory text) are built at tap time, never in the key.
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    isProcessing: vm.isProcessing,
                    canRevokeMemoryWrite: isRevocableMemoryWrite
                )) {
                    // [T-ios-tool-bubble-longpress-menu]
                    Button {
                        UIPasteboard.general.string = toolDetailsClipboard
                    } label: {
                        Label(AppLocalized("Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    // [T-ios-retry-hide-when-processing] Only expose the
                    // destructive Re-run action when the agent loop is idle.
                    // Re-running mid-stream would tear down an in-flight turn
                    // and confuse downstream state — hide both the divider and
                    // the button as a group so the menu doesn't leave a
                    // trailing separator with nothing under it.
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // Re-run the whole assistant turn that owns this
                            // tool_use. Routed via notification so we don't have
                            // to thread a vm closure through the 4-layer cell
                            // hosting chain — AIChatView's RerunFromToolBlockListener
                            // maps blockId → owning assistant msg → preceding user
                            // msg → vm.retryFromMessage.
                            NotificationCenter.default.post(
                                name: .rerunFromToolBlock,
                                object: nil,
                                userInfo: ["blockId": block.id]
                            )
                        } label: {
                            Label(AppLocalized("Re-run From Here"), systemImage: "arrow.clockwise")
                        }
                    }
                    // [T-ios-memory-write-revoke] Undo the daily-log entry this
                    // memory_write produced, without a detour through
                    // Memories in Session → detail sheet. Only appears for a
                    // memory_write that carries input args.
                    if isRevocableMemoryWrite {
                        Divider()
                        Button(role: .destructive) {
                            showRevokeMemoryAlert = true
                        } label: {
                            Label(AppLocalized("Undo This Memory Write"), systemImage: "trash.slash")
                        }
                    }
                }
                .equatable()
            }
            // Stop button for running commands — sibling of the row Button so
            // tapping it doesn't open the detail sheet.
            if case .running = block.toolStatus {
                Button {
                    onStop?()
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ChatColors.destructive)
                        .frame(width: 10, height: 10)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .padding(-3)
                }
                .buttonStyle(.plain)
            }
            // [T-tool-bg-suspended-hint] Yellow ⓘ just outside the capsule's
            // trailing edge when this tool was likely suspended by the OS in the
            // background. Tapping shows an alert offering to enable enhanced
            // background (deep-links to Settings → Permissions → Background).
            if showBgSuspendedHint {
                Button {
                    showBgHintAlert = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ChatColors.warning)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel(Text(AppLocalized("Background suspension info")))
            }
            Spacer(minLength: 0)
        }
        .alert(
            AppLocalized("Task may have been paused"),
            isPresented: $showBgHintAlert
        ) {
            Button(AppLocalized("Go Enable")) {
                // Deep-link to Settings → Permissions → Background, nudging the
                // recommended rows ON — they highlight only while still OFF
                // (= minis-clone://settings/background?focus=…:true,…:true). Location
                // Tracking is included so the background heartbeat that keeps the
                // task Live Activity refreshing in real time gets enabled too.
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(AppLocalized("Maybe Later"), role: .cancel) {}
        } message: {
            Text(AppLocalized("This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
        // [T-ios-memory-write-revoke] Mirrors the Revoke Memory confirmation in
        // SessionMemoryView: confirm, then report the outcome in place — the
        // user stays in the transcript, no navigation. The bubble itself is
        // left alone; only the underlying daily-log file changed.
        .alert(
            AppLocalized("Revoke Memory"),
            isPresented: $showRevokeMemoryAlert
        ) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Revoke"), role: .destructive) {
                // The menu item is gated on the cheap enum+args check, so the
                // `content` parse can still come back empty here (malformed or
                // still-streaming args). Report that rather than failing silently.
                if let written = memoryWriteContent {
                    revokeMemoryResult = MemoryWriteRevoker.revoke(writtenContent: written)
                } else {
                    revokeMemoryResult = AppLocalized("No written content to revoke.")
                }
                showRevokeMemoryResultAlert = true
            }
        } message: {
            Text(AppLocalized("Remove this memory entry from the daily log? This cannot be undone."))
        }
        .alert(revokeMemoryResult ?? "", isPresented: $showRevokeMemoryResultAlert) {
            Button(AppLocalized("OK")) {}
        }
        .onChange(of: isStreaming) { streaming in
            dotsActive = streaming
        }
        .onAppear {
            if isStreaming {
                dotsActive = true
            }
        }
    }

    // MARK: - Status / Icon

    @ViewBuilder
    private var statusOrIcon: some View {
        // [claude-style] Gray tool-type icon, ~16pt — no status coloring.
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(ChatColors.secondaryText)
    }

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

}

// MARK: - [chat-ui] Tool-Call Group Card (Kelivo-style folding)

/// Expanded/collapsed state for tool-call group cards.
///
/// Keyed by "<messageId>:<firstBlockId>" so the state survives the group
/// growing: appending a new tool block changes the item's groupKey (member
/// IDs), but the run's first block never changes — blocks are append-only.
/// Bounded (400 entries) so long sessions can't grow it without limit.
enum ToolGroupExpansion {
    private static var expandedKeys = Set<String>()
    private static let maxEntries = 400

    static func isExpanded(stateKey: String) -> Bool {
        expandedKeys.contains(stateKey)
    }

    static func toggle(stateKey: String) {
        if expandedKeys.contains(stateKey) {
            expandedKeys.remove(stateKey)
        } else {
            if expandedKeys.count >= maxEntries { expandedKeys.removeFirst() }
            expandedKeys.insert(stateKey)
        }
    }
}

/// [chat-ui] Folding card for >2 consecutive tool calls in one assistant turn.
/// Collapsed shows the header + the LAST 2 tool capsules (the running tool is
/// always the tail, so its stop button stays reachable); tap the header to
/// expand. Each row is the stock ToolCapsuleView — stop button, elapsed time,
/// tap-for-detail and the long-press menu (copy / re-run / memory undo) are
/// all preserved untouched.
struct ToolCallGroupCard: View {
    let blocks: [AssistantBlock]
    /// "<messageId>:<firstBlockId>" — see ToolGroupExpansion.
    let stateKey: String
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var detailBlock: AssistantBlock?

    private var isExpanded: Bool { ToolGroupExpansion.isExpanded(stateKey: stateKey) }

    private var visibleBlocks: [AssistantBlock] {
        isExpanded ? blocks : Array(blocks.suffix(2))
    }

    private var headerTitle: String {
        // English source keys — zh-Hans/zh-Hant live in Localizable.xcstrings.
        if isExpanded { return AppLocalized("Collapse tool calls") }
        return AppLocalized("Expand tool calls")
    }

    var body: some View {
        // [claude-style] No card chrome — just the minimal header + plain rows.
        VStack(alignment: .leading, spacing: 2) {
            Button {
                ToolGroupExpansion.toggle(stateKey: stateKey)
                NotificationCenter.default.post(name: .toolGroupToggled, object: stateKey)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .medium))
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(blocks.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChatColors.secondaryText.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(ChatColors.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)

            ForEach(visibleBlocks) { block in
                ToolCapsuleView(
                    block: block,
                    icon: AssistantBlockView.toolCapsuleIcon(for: block.kind),
                    accentColor: ChatColors.accent,
                    commandStartTime: commandStartTime,
                    onStop: onStop,
                    browserPool: AssistantBlockView.toolCapsuleNeedsBrowserPool(for: block.kind) ? browserPool : nil,
                    toolSnapshots: toolSnapshots,
                    detailBlock: $detailBlock
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}



extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// [chat-ui] Posted when a tool-call group card's header is tapped.
    /// object is the card's state key ("<messageId>:<firstBlockId>").
    /// The message list clears that cell's cached height and reconfigures it
    /// so UIHostingConfiguration re-measures — same shape as thinkingBlockToggled.
    static let toolGroupToggled = Notification.Name("toolGroupToggled")
    /// Posted when a long-press selection menu's "Add to Chat Input" action
    /// fires. userInfo["text"] is the selected text to append. The active
    /// chat's AIChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    /// Posted when an inline media attachment (image / video thumbnail /
    /// audio waveform) finishes async loading and its intrinsic content
    /// size changes. The collection view listens and invalidates self-sizing
    /// caches so cells re-measure. notification.object is the source URL
    /// string (for logging only — handler invalidates all visible cells).
    /// [T-attachment-size-invalidate 2026-05-21]
    static let minisAttachmentSizeChanged = Notification.Name("minisAttachmentSizeChanged")
    /// Posted from a tool capsule's long-press menu "Re-run from here".
    /// userInfo["blockId"] is the AssistantBlock.id (UUID) of the tapped
    /// tool_use. The active AIChatView listens, maps the block to its
    /// owning assistant message, finds the preceding user message, and
    /// re-runs the agent loop from there. [T-ios-tool-bubble-longpress-menu]
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// Listens for `.rerunFromToolBlock` and drives the re-run. Extracted into
/// its own ViewModifier (like ChatInputAppendListener) to keep AIChatView's
/// body within the Swift type-checker budget. [T-ios-tool-bubble-longpress-menu]
///
/// "Re-run from here" semantics (block boundary —
/// T-ios-rerun-from-tool-block-position): re-run from the exact point this
/// tool_use was about to be issued. retryFromToolBlock keeps the blocks
/// BEFORE the target tool_use within its assistant turn, drops the target
/// block + later blocks in that turn + all later messages (rewriting the
/// trimmed assistant row in the DB), then re-runs the agent loop. If the
/// target is the first block with nothing preceding it, that path degrades
/// to a preceding-user-message truncation automatically.
struct RerunFromToolBlockListener: ViewModifier {
    let vm: AIChatViewModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rerunFromToolBlock)) { note in
            guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
            vm.retryFromToolBlock(blockId: blockId)
            vm.forceScrollToBottom.send()
        }
    }
}

/// View-modifier wrapper around the `chatInputAppendRequested` listener.
/// Extracted out of AIChatView.body because that body sits at the Swift
/// type-checker's expression budget and inlining another `.onReceive` block
/// trips the "compiler unable to type-check this expression in reasonable
/// time" diagnostic.
/// Listens for `.dismissAllImmersivePresentations` and calls the host
/// view's clear method. Extracted into its own modifier so AIChatView's
/// body type stays demangleable — adding the onReceive directly to body
/// trips the Swift type-checker timeout (same class of issue as the
/// 2026-04-17 inputBar / 2026-05-24 attachmentMenu blow-ups).
struct DismissImmersiveCoversListener: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            onDismiss()
        }
    }
}

struct ChatInputAppendListener: ViewModifier {
    let vm: AIChatViewModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            // Focus the composer + pop the keyboard so the user can
            // immediately continue typing after a long-press → Add to Chat
            // Input. Independent of the post-reply auto-pop Settings
            // toggle (#354 / eb6d8164) — that gate is for *passive*
            // moments (reply finished, scroll, etc.); this is a direct
            // user gesture and should always focus. (T-add-to-input-focus)
            //
            // Async hop so the inputText `didSet` settles into the
            // composer's TextField before the focus binding flips —
            // without it the keyboard occasionally pops first and the
            // text appears mid-animation.
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

// MARK: - Thinking Block View

/// [T-thinkperf-release-displaylink] Retired hitch monitor.
///
/// This was a CADisplayLink that ticked at 60fps for the entire life of an
/// expanded, streaming thinking block, logging frame gaps > 100ms plus a
/// per-second frame summary. It was pure instrumentation for
/// T-thinking-stream-jank: nothing ever read it but its own log lines.
///
/// It has been removed rather than `#if DEBUG`-gated, for two reasons:
///
///  1. It shipped. The originating commit (7573e28b8) called it "cheap enough
///     to stay on in Debug" but never gated it, so every Release build ran the
///     display link in the field. A 60fps timer's cost is not its tick body
///     (85ms of main-thread CPU across a 209s Time Profiler trace, 2026-08-11)
///     but the main-thread wake-up it forces every frame, which keeps the CPU
///     out of idle. `stop()` only began a 25s grace window, so it kept ticking
///     for 18s after the stream ended — observed at 172-190s while the app was
///     otherwise idle at ~15ms/s. That is the shape of a battery complaint,
///     and a CPU-percentage view hides it.
///  2. A display link perturbs exactly what it claims to measure: holding the
///     frame pipeline active changes the frame timing being sampled.
///
/// The jank it was built to investigate was diagnosed and fixed (the follow
/// trigger moved from per-delta to flush pace). Should that work resume, prefer
/// Instruments over a permanent in-app probe on a per-frame path.
///
/// The type is kept as an inert stub so call sites stay put and no behaviour
/// depends on whether a probe happens to be compiled in.
@MainActor
final class ThinkingHitchMonitor {
    static let shared = ThinkingHitchMonitor()

    /// Retained so `ThinkingBlockView` keeps compiling; nothing reads it.
    var bodyEvalCount = 0
    var contentLenProvider: (() -> Int)?

    func start(owner: UUID) {}
    func stop(owner: UUID) {}
}

// MARK: - Thinking Block View (nested mode)

/// [T-nested-ui] Thinking block in nested mode. Two states, both at the
/// uniform inline height — the chat never reflows:
///
/// - Pure thinking (no tools called yet): a fixed-height drawer showing the
///   thinking content in an internally-scrollable area. The chat doesn't
///   flood no matter how long the thinking gets.
/// - Thinking with tools after it: collapses to a summary row (icon +
///   one-line summary + chevron). Tap pushes the detail page.
///
/// All colors come from theme tokens (ChatColors → AppearanceStudio,
/// scope: .chat). No hardcoded colors, no emoji, no card chrome.
struct ThinkingBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let isStreaming: Bool
    /// True when tool blocks come after this thinking block in the message.
    /// Drives the drawer → summary-row collapse.
    let hasToolsAfter: Bool
    /// Opens the detail page (parent pushes via NavigationStack).
    var onOpenDetail: (() -> Void)?

    @State private var thinkingStartTime: Date? = nil
    @State private var elapsedSeconds: Double = 0
    @State private var dotsActive = false

    /// The one-liner for the summary row: the LLM-generated natural summary
    /// once the turn completes, a working state while streaming, and a
    /// static label as the last resort.
    private var summaryLine: String {
        if let s = block.summary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if isStreaming {
            return AppLocalized("Thinking…")
        }
        return AppLocalized("Deep Thinking")
    }

    var body: some View {
        Group {
            if hasToolsAfter {
                thinkingSummaryRow
            } else {
                thinkingDrawer
            }
        }
        .id(appearanceStudio.themePackRevision)
        .onAppear {
            if isStreaming && thinkingStartTime == nil {
                thinkingStartTime = Date()
            }
        }
        .onChange(of: isStreaming) { streaming in
            if streaming {
                thinkingStartTime = Date()
                elapsedSeconds = 0
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if isStreaming, let start = thinkingStartTime {
                elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - Summary row (collapsed)

    /// [claude-style] Minimal row: icon + one-line summary + chevron.
    /// Tapping pushes the thinking detail page.
    /// [T-theme-no-hardcode] Font sizes from the theme pack (thinkingTitleSize).
    private var thinkingSummaryRow: some View {
        Button {
            onOpenDetail?()
        } label: {
            HStack(spacing: 8) {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(ChatColors.secondaryText)
                Text(summaryLine)
                    .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isStreaming {
                    // Bouncing dots while the turn is still working.
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { i in
                            Text(".")
                                .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                                .foregroundStyle(ChatColors.secondaryText)
                                .offset(y: dotsActive ? -2 : 1)
                                .animation(
                                    .easeInOut(duration: 0.35)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.12),
                                    value: dotsActive
                                )
                        }
                    }
                    .onAppear { dotsActive = true }
                    .onDisappear { dotsActive = false }
                } else if !isStreaming, block.summary == nil {
                    // Static label gets the elapsed time once done.
                    Text(elapsedLabel)
                        .font(.system(size: MinisThemeShape.thinkingBodySize, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: AssistantBlockView.nestedInlineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nestedDrawerBackground()
        .accessibilityLabel(Text(summaryLine))
    }

    // MARK: - Drawer (pure thinking)

    /// Fixed-height drawer with the thinking content in an internal
    /// ScrollView. Follows the tail while streaming.
    /// [T-theme-no-hardcode] Font sizes from the theme pack.
    private var thinkingDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — compact, icon + label + elapsed.
            HStack(spacing: 6) {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(ChatColors.secondaryText)
                Text(AppLocalized("Deep Thinking"))
                    .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                if isStreaming || elapsedSeconds > 0 {
                    Text(elapsedLabel)
                        .font(.system(size: MinisThemeShape.thinkingBodySize, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ChatColors.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Content — internally scrollable, chat never floods.
            ScrollViewReader { proxy in
                ScrollView {
                    Text(block.content.isEmpty ? block.thinkingContentBuffer : block.content)
                        .font(.system(size: MinisThemeShape.thinkingBodySize))
                        .foregroundStyle(ChatColors.tertiaryText)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .id("thinkingTail")
                }
                .onChange(of: block.content.count) { _ in
                    guard isStreaming else { return }
                    proxy.scrollTo("thinkingTail", anchor: .bottom)
                }
            }
        }
        .frame(height: AssistantBlockView.nestedInlineHeight)
        .nestedDrawerBackground()
    }

    private var elapsedLabel: String {
        let secs = Int(elapsedSeconds)
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m\(secs % 60)s"
    }
}


// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [Bool] = [false, false, false]
    /// Live Soul name so the indicator reads "<custom name> is thinking…" when
    /// the user has renamed the assistant in Soul settings. Updates via
    /// `.soulMdChanged` Notification — same wiring used by `AssistantSoulName`.
    @State private var soulName: String = {
        let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "我的小家" : n
    }()

    var body: some View {
        // The thinking-level badge that used to trail this indicator was
        // removed — the nav-bar title (AIChatView.thinkingLevelBadge) is now
        // the single place that shows and changes the thinking level, so a
        // duplicate here was redundant. ThinkingLevelSheetView is unchanged;
        // it's still presented from the nav-bar badge.
        HStack(spacing: 0) {
            Text("\(soulName) is thinking")
            ForEach(0..<3, id: \.self) { i in
                Text(".")
                    .offset(y: dotOffsets[i] ? -3 : 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            let n = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            soulName = n.isEmpty ? "我的小家" : n
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.top, 0)
        .onAppear {
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15)
                ) {
                    dotOffsets[i] = true
                }
            }
        }
    }
}

// MARK: - Thinking Level Sheet

struct ThinkingLevelSheetView: View {
    let currentLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        NavigationStack {
            List {
                thinkingRow(level: .off, isSelected: !currentLevel.isEnabled)
                Section {
                    ForEach(availableLevels, id: \.self) { level in
                        thinkingRow(level: level, isSelected: currentLevel == level)
                    }
                }
            }
            .navigationTitle(AppLocalized("Thinking Intensity"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thinkingRow(level: ThinkingLevel, isSelected: Bool) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(level == .off ? 0.4 : 1.0)
                Text(level.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ChatColors.accent)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tool Copy Button

private struct ToolCopyButton: View {
    var accentColor: Color = ChatColors.accent
    let content: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
                .foregroundStyle(copied ? accentColor : accentColor.opacity(0.4))
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}
