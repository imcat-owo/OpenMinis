import SwiftUI

// MARK: - Voice Services (kelivo-style TTS service list)
//
// [T-tts-services 09-11] The list page of the independent TTS layer. One row per
// configured service; a row's own vendor icon + name + "model · voice" summary,
// with a trailing check on the active one. Mirrors kelivo's tts_services_page:
//
//   Voice Services            [+]        ← add
//   ┌────────────────────────────────┐
//   │ ◉ System (Apple)          ▶ ⚙ ✓│    ← built-in, always present
//   │ ◉ ElevenLabs              ▶ ⚙ ✓│    ← configured services
//   │   eleven_multilingual_v2 · Rachel│
//   └────────────────────────────────┘
//   ┌────────────────────────────────┐
//   │ Auto-read replies          [○] │    ← playback settings
//   │ Cache audio for replay     [●] │
//   │ Read: Full text ▸              │
//   └────────────────────────────────┘
//
// The System row is NOT a TTSServiceOptions: it is the always-available offline
// engine, and selecting it means "no service" (the read-aloud path then falls
// back to the offline System voice). That keeps the new layer strictly additive.

struct VoiceServicesView: View {

    @ObservedObject private var output = VoiceOutputState.shared
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared

    @State private var editing: TTSServiceOptions?
    @State private var showAddSheet = false
    @State private var showSystemEditor = false
    /// TTSServiceStore is a plain Sendable (read from the synthesis queue too),
    /// not an ObservableObject — this throws on its change notification so the
    /// list re-renders on add / edit / delete / selection.
    @State private var storeRevision = 0

    /// The shared store; read fresh on every render (it is a plain Sendable).
    private var store: TTSServiceStore { TTSServiceStore.shared }

    var body: some View {
        List {
            servicesSection
            groupsSection
            playbackSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Voice Services")
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add voice service")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            storeRevision &+= 1
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                TTSServiceEditorView(service: nil)
            }
        }
        .sheet(item: $editing) { service in
            NavigationStack {
                TTSServiceEditorView(service: service)
            }
        }
        .sheet(isPresented: $showSystemEditor) {
            NavigationStack {
                SystemVoiceEditorView()
            }
        }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    // MARK: Services

    private var servicesSection: some View {
        Section {
            systemRow

            ForEach(store.services) { service in
                serviceRow(service)
            }
            .onDelete { indexSet in
                for i in indexSet {
                    let service = store.services[i]
                    store.remove(id: service.id)
                }
            }
        } header: {
            Text("Text-to-Speech")
        } footer: {
            Text("Pick which voice reads replies aloud. A service here is a complete synthesis target on its own — vendor, endpoint, key, model, voice and tuning. Nothing selected falls to the Voice Output model group. The built-in System voice only speaks when \"Allow System voice\" is on.")
        }
    }

    /// The built-in Apple engine — selectable; the gear opens the System voice
    /// editor (voice roster + pitch/volume/speed), same as any cloud service.
    /// [T-system-voice-off 09-12] 修复审查问题7: with the "Allow System voice"
    /// switch OFF this engine never speaks, so the row must SAY so — dimmed,
    /// "muted by setting" caption, and tapping it flips the setting instead of
    /// silently selecting a voice that can't sound.
    private var systemRow: some View {
        let isActive = store.selectedServiceId == nil
        let allowed = VoiceOutputPreferences.systemVoiceAllowed
        return Button {
            if allowed {
                store.setSelectedServiceId(nil)
            } else {
                // Tapping the muted System row turns it back on (one less hop
                // than scrolling to the Playback toggle).
                VoiceOutputPreferences.systemVoiceAllowed = true
                store.setSelectedServiceId(nil)
            }
        } label: {
            HStack(spacing: 12) {
                rowIcon(symbol: "apple.logo", active: isActive && allowed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System (Apple)")
                        .foregroundStyle(allowed ? MinisTheme.primaryText : MinisTheme.secondaryText)
                    Text(allowed
                         ? "Offline · on-device voice"
                         : "Muted — tap to allow System voice")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                Spacer()
                trailingControls(system: true, active: isActive)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: TTS Groups

    /// [tts-groups 2026-10-02] 分组入口：对标 API 的模型分组列表。
    private var groupsSection: some View {
        Section {
            NavigationLink {
                TTSGroupsView()
            } label: {
                HStack(spacing: 12) {
                    rowIcon(symbol: "square.stack.3d.up.fill",
                            active: TTSGroupStore.shared.defaultGroupId != nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TTS 分组")
                            .foregroundStyle(MinisTheme.primaryText)
                        Text(groupSubtitle)
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
        } header: {
            Text("分组")
        } footer: {
            Text("把多个 TTS 服务装进一个分组，发语音时按顺序自动切换。")
        }
    }

    private var groupSubtitle: String {
        let store = TTSGroupStore.shared
        if let gid = store.defaultGroupId, let g = store.group(id: gid) {
            let n = store.candidates(for: g).count
            return "默认：\(g.name)（\(n) 个可用服务）"
        }
        return store.groups.isEmpty ? "还没建分组" : "\(store.groups.count) 个分组，未设默认"
    }

    private func serviceRow(_ service: TTSServiceOptions) -> some View {
        let isActive = store.selectedServiceId == service.id
        return Button {
            store.setSelectedServiceId(service.id)
        } label: {
            HStack(spacing: 12) {
                rowIcon(symbol: service.kind.symbol, active: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .foregroundStyle(service.enabled ? MinisTheme.primaryText : MinisTheme.secondaryText)
                    Text("\(service.model) · \(service.voice)")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                trailingControls(system: false, active: isActive, service: service)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.remove(id: service.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editing = service
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(MinisTheme.accent)
        }
    }

    private func rowIcon(symbol: String, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? MinisTheme.accent.opacity(0.15) : MinisTheme.mutedSurface)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? MinisTheme.accent : MinisTheme.secondaryText)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private func trailingControls(system: Bool, active: Bool, service: TTSServiceOptions? = nil) -> some View {
        HStack(spacing: 18) {
            if system {
                // System engine: gear opens the system-voice editor sheet.
                Button {
                    showSystemEditor = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit System voice")
            }
            if let service {
                // Test-listen: synthesizes a short phrase through this service
                // right from the list (uses the SAVED definition + stored key).
                Button {
                    preview(service)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Test \(service.name)")
            }
            if !system, let service {
                Button {
                    editing = service
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(service.name)")
            }
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(active ? MinisTheme.accent : MinisTheme.secondaryText.opacity(0.4))
        }
    }

    /// List-level test: synthesize a short phrase via the saved service and
    /// play it. Errors surface as a toast, not an inline label (the editor
    /// has the richer inline test experience).
    @State private var previewing = false
    private func preview(_ service: TTSServiceOptions) {
        guard !previewing else { return }
        previewing = true
        Task { @MainActor in
            defer { previewing = false }
            do {
                guard let provider = TTSProviderBridge.provider(for: service) else {
                    throw VoiceProviderError.unsupported("This vendor cannot synthesize speech")
                }
                let request = TTSProviderBridge.request(for: service, text: service.previewSentence)
                let data = try await provider.synthesize(request)
                guard !data.isEmpty else { throw VoiceProviderError.noAudioData }
                // [T-tts-vendor-fix 09-13] Play via the shared TTSPreviewPlayer:
                // it stops the previous preview (no stacking) and ENDS the
                // .replyTTS intent on finish (the old local-player leak kept
                // the audio session in .playback forever — audit #6/#11).
                try TTSPreviewPlayer.shared.play(data)
            } catch {
                MinisToast.show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { VoiceOutputPreferences.isEnabled },
                set: { output.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-read replies")
                    Text("Read each new reply aloud as it arrives")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            Toggle(isOn: Binding(
                get: { VoiceOutputPreferences.cacheNetworkAudio },
                set: { VoiceOutputPreferences.cacheNetworkAudio = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache audio for replay")
                    Text("Keep synthesized audio so replaying costs nothing")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            // [T-system-voice-off 09-12] 醒醒 3: System voice is opt-in. OFF
            // (default) = the built-in Apple voice never speaks — replies use
            // your TTS service / voice group only, and stay silent when those
            // are unusable, instead of falling back to the robotic engine.
            Toggle(isOn: Binding(
                get: { VoiceOutputPreferences.systemVoiceAllowed },
                set: { VoiceOutputPreferences.systemVoiceAllowed = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow System voice")
                    Text("OFF = only your configured voices speak; never the built-in Apple voice")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            Picker(selection: Binding(
                get: { VoiceOutputPreferences.selectionMode },
                set: { VoiceOutputPreferences.selectionMode = $0 }
            )) {
                ForEach(VoiceTextSanitizer.SelectionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read")
                    Text("Which part of a reply is spoken")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
        } header: {
            Text("Playback")
        }
    }
}

// MARK: - Selection mode labels

extension VoiceTextSanitizer.SelectionMode {
    var displayName: String {
        switch self {
        case .fullText:           return "Full text"
        case .quotedOnly:         return "Quoted text only"
        case .withoutParentheses: return "Skip parentheses"
        }
    }
}
