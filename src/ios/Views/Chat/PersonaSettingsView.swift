import SwiftUI
import PhotosUI

// MARK: - PersonaSettingsView
//
// 编辑一个人设：名字、头像、人设提示词（SOUL.md 正文）、
// skill 开关、MCP 开关。v1 最小可用，界面跟着 App 现有风格走。

struct PersonaSettingsView: View {
    @ObservedObject var store: PersonaStore
    let personaID: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var avatarURI: String? = nil
    @State private var soulBody: String = ""
    @State private var enabledSkillIds: Set<String> = []
    @State private var enabledMcpIds: Set<String> = []
    @State private var loaded = false

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var iconError: String?

    private var persona: Persona? {
        store.personas.first { $0.id == personaID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    HStack {
                        PersonaAvatarView(iconRef: avatarURI, size: 52)
                        Button("换头像") { showPhotoPicker = true }
                            .font(.callout)
                        if avatarURI != nil {
                            Button("去掉") { avatarURI = nil; saveAvatar() }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("名字", text: $name)
                        .onSubmit { saveName() }
                }

                Section("人设提示词") {
                    Text("这就是 SOUL.md 的正文，决定它说话的性格和身份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $soulBody)
                        .frame(minHeight: 220)
                        .font(.body)
                }

                Section("Skill") {
                    Text("关掉的不再进它的 system prompt。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(SkillStore.shared.skills) { skill in
                        Toggle(skill.name, isOn: Binding(
                            get: { enabledSkillIds.contains(skill.id) },
                            set: { on in
                                if on { enabledSkillIds.insert(skill.id) }
                                else { enabledSkillIds.remove(skill.id) }
                                saveSkillWhitelist()
                            }
                        ))
                    }
                }

                Section("MCP") {
                    Text("关掉的不再进它的 system prompt。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(MCPStore.shared.servers) { server in
                        Toggle(server.id, isOn: Binding(
                            get: { enabledMcpIds.contains(server.id) },
                            set: { on in
                                if on { enabledMcpIds.insert(server.id) }
                                else { enabledMcpIds.remove(server.id) }
                                saveMcpWhitelist()
                            }
                        ))
                    }
                }

                if persona?.isBuiltIn == true {
                    Section {
                        Text("这是内置人设，删不掉。提示词可以改，但改了之后它的 MCP 管家身份可能会变味。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑人设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") { saveAll(); dismiss() }
                }
            }
            .onAppear { loadOnce() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                          matching: .images, photoLibrary: .shared())
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await applyPickedImage(newItem) }
            }
            .alert("这张图用不了", isPresented: Binding(
                get: { iconError != nil }, set: { if !$0 { iconError = nil } }
            )) {
                Button("好", role: .cancel) { iconError = nil }
            } message: {
                Text(iconError ?? "")
            }
        }
    }

    // MARK: - load / save

    private func loadOnce() {
        guard !loaded, let p = persona else { return }
        loaded = true
        name = p.name
        avatarURI = p.avatar
        if let file = SoulStore.load(for: personaID) {
            soulBody = file.body
        }
        let allSkillIds = Set(SkillStore.shared.skills.map(\.id))
        enabledSkillIds = p.skillIds.map(Set.init) ?? allSkillIds
        let allMcpIds = Set(MCPStore.shared.servers.map(\.id))
        enabledMcpIds = p.mcpServerIds.map(Set.init) ?? allMcpIds
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renamePersona(personaID, to: trimmed)
    }

    private func saveAvatar() {
        guard var p = persona else { return }
        p.avatar = avatarURI
        store.updatePersona(p)
    }

    private func saveSoul() {
        var file = SoulStore.load(for: personaID)
            ?? SoulFile(metadata: .default, body: "")
        file.body = soulBody
        try? SoulStore.save(file, for: personaID)
    }

    private func saveSkillWhitelist() {
        guard var p = persona else { return }
        let all = Set(SkillStore.shared.skills.map(\.id))
        p.skillIds = (enabledSkillIds == all) ? nil : Array(enabledSkillIds)
        store.updatePersona(p)
    }

    private func saveMcpWhitelist() {
        guard var p = persona else { return }
        let all = Set(MCPStore.shared.servers.map(\.id))
        p.mcpServerIds = (enabledMcpIds == all) ? nil : Array(enabledMcpIds)
        store.updatePersona(p)
    }

    private func saveAll() {
        saveName()
        saveAvatar()
        saveSoul()
        saveSkillWhitelist()
        saveMcpWhitelist()
    }

    private func applyPickedImage(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else {
            await MainActor.run { iconError = "这张图读不出来，换一张试试。" }
            return
        }
        // [avatar-file] Stored as a file reference, never inline base64.
        let name = SoulIconImage.storedName(prefix: "persona", id: personaID)
        switch SoulIconImage.store(image, named: name) {
        case .success(let path):
            await MainActor.run {
                avatarURI = path
                saveAvatar()
            }
        case .failure:
            await MainActor.run { iconError = "这张图读不出来，换一张试试。" }
        }
    }
}
