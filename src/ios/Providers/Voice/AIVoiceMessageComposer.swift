import Foundation

// MARK: - AI voice-message composer
//
// [T-ai-voice-messages 09-12] 醒醒 2：「我想要里面的ai自己也能发语音，发出来就是
// 自动播放的。有气泡UI像wx那样会动的，有动态效果。」
//
// Flow (triggered from StreamEnd when per-session "AI Voice Replies" is ON):
//   1. Sanitize the assistant text (strip markdown, keep plain text).
//   2. Synthesize via the read-aloud candidate chain (service → group → System).
//   3. Write the WAV bytes to the session's attachments dir.
//   4. Return a minis-clone:// URL + duration for the caller to embed into a
//      markdown audio link. The link renders as a WX-style voice bubble via
//      AudioAttachment (detects `voice_bubble=1` query param).

@MainActor
enum AIVoiceMessageComposer {

    private static let logger = AppLogger(category: "AIVoiceComposer")

    /// Result: (minis-clone URL String, duration in seconds).
    struct Result {
        let url: String
        let duration: Double
    }

    private static func prefKey(_ sid: String) -> String { "ai.voiceReplies.\(sid)" }

    static func voiceRepliesEnabled(sessionId: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefKey(sessionId))
    }

    static func setVoiceReplies(enabled: Bool, sessionId: String) {
        UserDefaults.standard.set(enabled, forKey: prefKey(sessionId))
    }

    /// [T-voice-bubble-context-clean 09-12] True when an assistant text part is
    /// ONLY a wx-style voice bubble this app composed. Such rows are DB/UI-only:
    /// loadSession keeps them OUT of agentHistory so the model never sees (and
    /// never imitates) its own bubble markdown. Shape-anchored, not
    /// substring-anchored: a normal reply that merely MENTIONS "voice_bubble=1"
    /// must never be stripped (unit-tested boundary: a 29-char reply mentioning
    /// the param stays; only an actual `![voice](…voice_bubble=1…)` link part
    /// goes).
    nonisolated static func isVoiceBubbleOnlyText(_ s: String) -> Bool {
        guard s.hasPrefix("![voice](") else { return false }
        guard s.contains("voice_bubble=1") else { return false }
        return s.count < 200
    }

    /// Synthesize the assistant reply text and persist the audio in the session's
    /// attachments dir. Returns a minis-clone:// URL ready for embedding into a
    /// `![voice](...)` markdown link. All errors (empty text, every candidate
    /// failed) are logged and return nil. [AI-P2-3] The caller owns the
    /// user-visible side of nil: it toasts the failure AND appends a
    /// <system-reminder> trace to the in-memory assistant message so the model
    /// knows no voice bubble went out — the nil itself stays silent here.
    static func compose(for text: String, sessionId: String) async -> Result? {
        let sanitized = VoiceTextSanitizer.sanitize(text, mode: .fullText)
        guard !sanitized.isEmpty else { return nil }

        let data: Data
        let dur: Double
        do {
            (data, dur) = try await synthesizeFull(sanitized)
        } catch {
            logger.warning("voice message synthesis failed: \(error.localizedDescription)")
            return nil
        }
        guard !data.isEmpty else { return nil }

        let ext = Self.isWAVData(data) ? "wav" : "mp3"
        let fname = "tts-\(UUID().uuidString.prefix(8)).\(ext)"
        let hostDir = AIChatViewModel.minisAttachmentsPersistentDir(for: sessionId)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let dest = hostDir.appendingPathComponent(fname)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            logger.warning("voice message write failed: \(error.localizedDescription)")
            return nil
        }
        let linuxPath = "/var/minis/attachments/\(fname)"
        let minisURL = "minis-clone://attachments/\(fname.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fname)"
        logger.info("voice message composed: \(linuxPath) dur=\(String(format: "%.1f", dur))s size=\(data.count)")
        return Result(url: minisURL, duration: dur)
    }

    /// Walk the candidate chain exactly like read-aloud: selected service →
    /// model group. [T-system-voice-off 09-12] 醒醒 3: System voice is an
    /// EXPLICIT fallback, not a silent one — when nothing user-configured is
    /// usable we throw instead of falling to AVSpeechSynthesizer, so the turn
    /// reads as text-only and the log names the gap. The old always-System
    /// tail made every misconfigured session sound like the robotic system
    /// voice 醒醒 hates.
    private static func synthesizeFull(_ text: String) async throws -> (Data, Double) {
        if let (data, _) = try? await synthesizeWithServiceOrGroup(text) {
            return (data, VoiceOutputPlayer.wavDurationOf(data))
        }
        throw VoiceProviderError.parseError(
            "no usable TTS target — select a TTS service or voice group first")
    }

    /// linuxPathFor(url:) — turn the minis-clone URL back into the /var/minis
    /// path (used by the auto-play trigger's resolvePathForDirectRead).
    nonisolated static func linuxPathFor(url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host else { return "" }
        let sub = comps.percentEncodedPath.isEmpty ? "" : "/" + (comps.percentEncodedPath.dropFirst().removingPercentEncoding ?? String(comps.percentEncodedPath.dropFirst()))
        return "/var/minis/\(host)\(sub)"
    }

    /// [TTS-11] RIFF/WAVE magic check — the saved bubble's extension must
    /// describe the actual bytes (the old code guessed from whether a
    /// WAV duration could be read, which mislabels any vendor that
    /// returns WAV where MP3 was requested and vice versa).
    nonisolated static func isWAVData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.subdata(in: 0..<4) == Data("RIFF".utf8)
            && data.subdata(in: 8..<12) == Data("WAVE".utf8)
    }

    /// [TTS-11] Synthesize `text` through `synth`, splitting UP FRONT at
    /// `limit` characters on sentence boundaries when the text exceeds
    /// it, then joining the pieces into one blob with the read-aloud
    /// path's concat rules. A long reply used to go out as ONE request:
    /// past the vendor's per-request cap (Doubao 1024, OpenAI 4096, …)
    /// the whole bubble failed and the reply stayed text-only. Any
    /// chunk failing fails the whole bubble, same as before.
    /// [AI-P2-4] Each chunk now goes through `synthWithRetry` below —
    /// same-text retries with backoff, then split-smaller — mirroring
    /// read-aloud's `VoiceOutputPlayer.synthWithRetry` instead of the old
    /// single attempt per chunk (one network hiccup used to kill the
    /// whole long-reply bubble).
    private static func synthesizeChunked(
        _ text: String, limit: Int,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let chunks = VoiceOutputPlayer.splitText(text, maxChars: limit)
        guard chunks.count > 1 else { return try await synthWithRetry(text, synth) }
        var pieces: [Data] = []
        for chunk in chunks {
            let d = try await synthWithRetry(chunk, synth)
            guard !d.isEmpty else { throw VoiceProviderError.noAudioData }
            pieces.append(d)
        }
        logger.info("[AIVoice] long reply synthesized in \(chunks.count) chunks (limit \(limit))")
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [AI-P2-4] Two-phase resilience for one chunk, mirroring read-aloud's
    /// `VoiceOutputPlayer.synthWithRetry` (same retry counts/backoff/split
    /// size, shared constants): Phase 1 retries the SAME text with backoff;
    /// Phase 2 splits into smaller pieces and synthesizes those. Empty audio
    /// counts as a failed attempt. Throws only when both phases fail.
    private static func synthWithRetry(
        _ text: String,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let maxAttempts = VoiceOutputPlayer.synthRetriesSameText
        var lastError: Error?
        // Phase 1: retry the same text.
        for attempt in 0...maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let d = try await synth(text)
                if !d.isEmpty { return d }
                lastError = VoiceProviderError.noAudioData
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            logger.warning("[AIVoice] chunk synth attempt \(attempt + 1)/\(maxAttempts + 1) failed: \(lastError?.localizedDescription ?? "?")")
            let backoff = VoiceOutputPlayer.synthRetryBackoff * Double(attempt + 1)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
        }
        // Phase 2: split smaller and synthesize each piece.
        let small = VoiceOutputPlayer.splitText(text, maxChars: VoiceOutputPlayer.synthSplitChunkChars)
        guard small.count > 1 else { throw lastError ?? VoiceProviderError.parseError("chunk synth failed") }
        logger.info("[AIVoice] chunk still failing — retrying as \(small.count) smaller pieces")
        var pieces: [Data] = []
        for piece in small {
            if Task.isCancelled { throw CancellationError() }
            var ok = false
            for _ in 0...maxAttempts {
                do {
                    let d = try await synth(piece)
                    if !d.isEmpty { pieces.append(d); ok = true; break }
                    lastError = VoiceProviderError.noAudioData
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
                try? await Task.sleep(nanoseconds: UInt64(VoiceOutputPlayer.synthRetryBackoff * 1e9))
            }
            guard ok else { throw lastError ?? VoiceProviderError.parseError("small-piece synth failed") }
        }
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [tts-groups 2026-10-02] 候选链：默认 TTS 分组成员（按分组顺序）→ 之前选中
    /// 的单个服务（兼容老配置）→ Voice Output 模型分组。没建分组时行为和以前
    /// 完全一致（选中服务 → 模型分组）。
    private static func synthesizeWithServiceOrGroup(_ text: String) async throws -> (Data, String?) {
        for service in ttsServiceCandidates() {
            if let result = await synthesizeWithService(service, text) {
                return result
            }
        }
        for entry in VoiceProviderResolver.resolvedOutputCandidates() {
            guard let provider = VoiceProviderResolver.outputProvider(for: entry) else { continue }
            // [TTS-11] Group entries carry no vendor kind here — split at
            // the conservative shared limit (safe for every vendor).
            if let data = try? await synthesizeChunked(text, limit: 1000, { chunk in
                try await provider.synthesize(VoiceOutputRequest(input: chunk, model: entry.model.id))
            }), !data.isEmpty {
                logger.info("[AIVoice] synthesized via model-group entry \(entry.model.displayName)")
                return (data, VoiceProviderResolver.isSystemEntry(entry.providerInstanceId) ? "wav" : "mp3")
            }
        }
        throw VoiceProviderError.parseError("all voice candidates failed")
    }

    /// 有序去重的 TTS 服务候选：默认分组成员优先，然后是选中的单个服务。
    private static func ttsServiceCandidates() -> [TTSServiceOptions] {
        var out: [TTSServiceOptions] = []
        var seen = Set<String>()
        for s in TTSGroupStore.shared.defaultGroupCandidates() where seen.insert(s.id).inserted {
            out.append(s)
        }
        let svcStore = TTSServiceStore.shared
        if let s = svcStore.selectedService(), s.enabled, seen.insert(s.id).inserted {
            out.append(s)
        }
        return out
    }

    /// 单个 TTS 服务合成一次。任何失败都记 LOUD 日志并返回 nil（调用方继续下
    /// 一个候选）。[T-tts-key-status 09-13] 语义保留：选中的服务自己的失败必须
    /// 大声记原因（之前"有声但显示没 key"就是这里静默跳过导致的）。
    private static func synthesizeWithService(_ service: TTSServiceOptions, _ text: String) async -> (Data, String)? {
        let svcStore = TTSServiceStore.shared
        if !svcStore.hasAPIKey(for: service) {
            logger.warning("[AIVoice] TTS service '\(service.name)' has NO stored key — skipping (check the Keychain save in the service editor)")
            return nil
        }
        guard let provider = TTSProviderBridge.provider(for: service) else {
            logger.warning("[AIVoice] TTS service '\(service.name)' (\(service.kind.rawValue)) cannot synthesize — skipping")
            return nil
        }
        do {
            // [TTS-11] Split at THIS vendor's per-request limit before sending,
            // not after a failure.
            let data = try await synthesizeChunked(text, limit: service.kind.bubbleSynthesisCharLimit) { chunk in
                try await provider.synthesize(TTSProviderBridge.request(for: service, text: chunk))
            }
            if !data.isEmpty {
                logger.info("[AIVoice] synthesized via service '\(service.name)' (\(service.kind.rawValue))")
                return (data, service.kind == .azure ? "mp3" : "wav")
            }
            logger.warning("[AIVoice] service '\(service.name)' returned empty audio — trying next candidate")
        } catch {
            logger.warning("[AIVoice] service '\(service.name)' synth failed: \(error.localizedDescription) — trying next candidate")
        }
        return nil
    }
}
