import SwiftUI

// MARK: - PersonaContactsView
//
// 微信/QQ 风格的人设通讯录：
// - 无粗暴的“人设”大标题，沉浸式列表
// - 点任意联系人（人设）可直接发起对话、切换会话，或直接编辑提示词（SOUL.md）
// - 支持右上角添加新人设

struct PersonaContactsView: View {
    @ObservedObject var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    var onSelectAndChat: ((Persona) -> Void)?

    @State private var selectedPersona: Persona?
    @State private var editingPersona: Persona?
    @State private var showNewSheet = false
    @State private var newName = ""
    @State private var deleteTarget: Persona?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.personas) { persona in
                        Button {
                            selectedPersona = persona
                        } label: {
                            HStack(spacing: 14) {
                                PersonaAvatarView(iconRef: persona.avatar, size: 44)
                                    .overlay(
                                        Circle()
                                            .stroke(persona.id == store.currentPersonaID ? MinisThemeList.accent : Color.clear, lineWidth: 2)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(persona.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(ChatColors.primaryText)

                                        if persona.isBuiltIn {
                                            Text("内置")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                                .foregroundStyle(.secondary)
                                        }

                                        if persona.id == store.currentPersonaID {
                                            Text("使用中")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(MinisThemeList.accent.opacity(0.15)))
                                                .foregroundStyle(MinisThemeList.accent)
                                        }
                                    }

                                    Text(personaBio(for: persona))
                                        .font(.system(size: 12))
                                        .foregroundStyle(ChatColors.secondaryText)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ChatColors.tertiaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !persona.isBuiltIn && store.personas.count > 1 {
                                Button(role: .destructive) {
                                    deleteTarget = persona
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            Button {
                                if let copy = store.duplicatePersona(persona.id) {
                                    selectedPersona = copy
                                }
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("所有联系人")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatColors.secondaryText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        showNewSheet = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .sheet(item: $selectedPersona) { persona in
                PersonaContactDetailSheet(persona: persona, store: store) {
                    dismiss()
                    onSelectAndChat?(persona)
                }
            }
            .alert("新建联系人", isPresented: $showNewSheet) {
                TextField("联系人名字", text: $newName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let p = store.addPersona(name: trimmed)
                    selectedPersona = p
                }
            }
            .alert("确认删除联系人", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let target = deleteTarget {
                        store.deletePersona(target.id)
                        deleteTarget = nil
                    }
                }
            } message: {
                if let target = deleteTarget {
                    Text("确定要删除「\(target.name)」吗？该人设的专属记忆将一并清除。")
                }
            }
        }
    }

    private func personaBio(for persona: Persona) -> String {
        let soulURL = PersonaStore.memoryDir(for: persona.id).appendingPathComponent("SOUL.md")
        if let text = try? String(contentsOf: soulURL, encoding: .utf8), !text.isEmpty {
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return lines.first?.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) ?? "暂无个性签名"
        }
        return persona.isBuiltIn ? "系统内置专属助手" : "点击查看并编辑提示词"
    }
}

// MARK: - Persona Contact Detail Sheet

struct PersonaContactDetailSheet: View {
    @State var persona: Persona
    @ObservedObject var store: PersonaStore
    var onChat: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEditingSoul = false
    @State private var soulContent = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Profile Header
                    VStack(spacing: 10) {
                        PersonaAvatarView(iconRef: persona.avatar, size: 76)
                            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)

                        Text(persona.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(ChatColors.primaryText)

                        if persona.id == store.currentPersonaID {
                            Text("当前活跃人设")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(MinisThemeList.accent.opacity(0.15)))
                                .foregroundStyle(MinisThemeList.accent)
                        }
                    }
                    .padding(.top, 16)

                    // Action Button: 发起对话
                    Button {
                        store.setCurrent(persona.id)
                        dismiss()
                        onChat()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("发消息 / 开始对话")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(MinisThemeList.accent))
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)

                    // SOUL / 提示词 Preview & Editor
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("人设设定 (SOUL.md)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ChatColors.primaryText)
                            Spacer()
                            Button {
                                loadSoulContent()
                                isEditingSoul = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil")
                                    Text("编辑提示词")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MinisThemeList.accent)
                            }
                        }

                        Text(soulContent.isEmpty ? "点击「编辑提示词」为Ta编写专属人格与灵魂…" : soulContent)
                            .font(.system(size: 13))
                            .foregroundStyle(ChatColors.secondaryText)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ChatColors.secondaryBg))
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle(persona.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSoulContent()
            }
            .sheet(isPresented: $isEditingSoul) {
                NavigationStack {
                    VStack(spacing: 0) {
                        TextEditor(text: $soulContent)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(10)
                    }
                    .navigationTitle("编辑设定")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isEditingSoul = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                saveSoulContent()
                                isEditingSoul = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private func loadSoulContent() {
        let soulURL = PersonaStore.memoryDir(for: persona.id).appendingPathComponent("SOUL.md")
        if let text = try? String(contentsOf: soulURL, encoding: .utf8) {
            soulContent = text
        }
    }

    private func saveSoulContent() {
        let soulURL = PersonaStore.memoryDir(for: persona.id).appendingPathComponent("SOUL.md")
        try? FileManager.default.createDirectory(at: soulURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? soulContent.write(to: soulURL, atomically: true, encoding: .utf8)
        SoulStore.refreshCache()
        NotificationCenter.default.post(name: .soulMdChanged, object: nil)
    }
}
