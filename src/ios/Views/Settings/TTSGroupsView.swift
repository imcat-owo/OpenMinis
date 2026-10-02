import SwiftUI

// MARK: - TTS 分组列表
//
// [tts-groups 2026-10-02] 对标 Providers/ModelGroupsView：TTS 服务分组列表。
// 分组 = 有序的多个 TTS 服务，合成时按顺序 fallback。默认分组由
// AIVoiceMessageComposer.synthesizeWithServiceOrGroup 优先使用。

struct TTSGroupsView: View {
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @State private var revision = 0
    @State private var showCreate = false
    @State private var newName = ""
    @State private var pendingDelete: TTSGroup?

    private var store: TTSGroupStore { TTSGroupStore.shared }

    var body: some View {
        List {
            if store.groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text("还没有 TTS 分组")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("把多个 TTS 服务装进一个分组，发语音时按顺序自动切换——第一个挂了换下一个。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                Section {
                    ForEach(store.groups) { group in
                        NavigationLink {
                            TTSGroupDetailView(groupId: group.id)
                        } label: {
                            groupRow(group)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = group
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveGroups)
                } header: {
                    HStack {
                        Text("TTS 分组")
                        Spacer()
                        EditButton()
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                Section {
                    Picker("默认分组", selection: Binding(
                        get: { store.defaultGroupId ?? "" },
                        set: { store.setDefaultGroupId($0.isEmpty ? nil : $0) }
                    )) {
                        Text("不分组（用单个服务）").tag("")
                        ForEach(store.groups) { g in
                            Text(g.name).tag(g.id)
                        }
                    }
                } footer: {
                    Text("发语音（AI 语音回复、send_voice）优先走默认分组里的服务，按顺序自动切换。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("TTS 分组")
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建 TTS 分组")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            revision &+= 1
        }
        .alert("新建分组", isPresented: $showCreate) {
            TextField("分组名", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") {
                store.createGroup(name: newName)
                newName = ""
            }
        }
        .alert("删除分组？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let g = pendingDelete { store.removeGroup(id: g.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("分组里的服务不受影响，只是解散这个分组。")
        }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    private func groupRow(_ group: TTSGroup) -> some View {
        let isDefault = store.defaultGroupId == group.id
        let members = store.candidates(for: group)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDefault ? MinisTheme.accent.opacity(0.15) : MinisTheme.mutedSurface)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDefault ? MinisTheme.accent : MinisTheme.secondaryText)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .foregroundStyle(MinisTheme.primaryText)
                    if isDefault {
                        Text("默认")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MinisTheme.accent.opacity(0.15)))
                            .foregroundStyle(MinisTheme.accent)
                    }
                }
                Text(members.isEmpty ? "没有可用服务" : members.map { $0.name }.joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(MinisTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        store.moveGroup(from: source, to: destination)
    }
}

// MARK: - TTS 分组详情：改名＋成员管理（顺序 = fallback 顺序）

struct TTSGroupDetailView: View {
    let groupId: String

    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @State private var revision = 0
    @State private var name = ""
    @State private var didLoadName = false

    private var store: TTSGroupStore { TTSGroupStore.shared }
    private var serviceStore: TTSServiceStore { TTSServiceStore.shared }
    private var group: TTSGroup? { store.group(id: groupId) }

    var body: some View {
        List {
            Section("名称") {
                TextField("分组名", text: $name)
                    .onSubmit { saveName() }
            }

            if let g = group {
                Section {
                    let members = memberRows(for: g)
                    if members.isEmpty {
                        Text("还没有服务，去下面添加。")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                    ForEach(members, id: \.id) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.service?.kind.symbol ?? "questionmark.circle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MinisTheme.secondaryText)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.service?.name ?? "已删除的服务")
                                    .foregroundStyle(MinisTheme.primaryText)
                                Text(row.service.map { "\($0.kind.displayName)·音色 \($0.voice)" } ?? "这个服务已经删了，顺序保留")
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Spacer()
                            if let s = row.service, !s.enabled {
                                Text("已停用")
                                    .font(.caption2)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                removeMember(row.id, from: g)
                            } label: {
                                Label("移出", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, dest in moveMember(from: source, to: dest, in: g) }
                } header: {
                    HStack {
                        Text("成员服务（按顺序 fallback）")
                        Spacer()
                        EditButton()
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                let available = serviceStore.services.filter { s in !g.memberServiceIds.contains(s.id) }
                if !available.isEmpty {
                    Section("添加服务") {
                        ForEach(available) { s in
                            Button {
                                var updated = g
                                updated.memberServiceIds.append(s.id)
                                store.updateGroup(updated)
                            } label: {
                                HStack {
                                    Text(s.name).foregroundStyle(MinisTheme.primaryText)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(MinisTheme.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("编辑分组")
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            revision &+= 1
        }
        .onAppear {
            if !didLoadName, let g = group {
                name = g.name
                didLoadName = true
            }
        }
        .onDisappear { saveName() }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    private struct MemberRow {
        let id: String
        let service: TTSServiceOptions?
    }

    private func memberRows(for g: TTSGroup) -> [MemberRow] {
        g.memberServiceIds.map { MemberRow(id: $0, service: serviceStore.service(id: $0)) }
    }

    private func saveName() {
        guard var g = group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != g.name else { return }
        g.name = trimmed
        store.updateGroup(g)
    }

    private func removeMember(_ serviceId: String, from g: TTSGroup) {
        var updated = g
        updated.memberServiceIds.removeAll { $0 == serviceId }
        store.updateGroup(updated)
    }

    private func moveMember(from source: IndexSet, to destination: Int, in g: TTSGroup) {
        var updated = g
        var ids = updated.memberServiceIds
        let items = source.sorted().map { ids[$0] }
        for idx in source.sorted(by: >) { ids.remove(at: idx) }
        let dest = destination - source.filter { $0 < destination }.count
        ids.insert(contentsOf: items, at: max(0, min(dest, ids.count)))
        updated.memberServiceIds = ids
        store.updateGroup(updated)
    }
}
