import PhotosUI
import SwiftUI
import UIKit

struct AppearanceStudioView: View {
    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var variant: AppearanceVariant = .light
    @State private var wallpaperScope: AppearanceScope = .global
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var userAvatarItem: PhotosPickerItem?
    @State private var assistantAvatarItem: PhotosPickerItem?
    @State private var iconPickSlot: QuietIconSlot?
    @State private var iconItem: PhotosPickerItem?
    @State private var thinkingCardItem: PhotosPickerItem?
    @State private var inputBarItem: PhotosPickerItem?
    @State private var categoryImageKey: String?
    @State private var categoryImageItem: PhotosPickerItem?
    @State private var saveName: String = ""
    @State private var errorText: String?
    // [T-appearance-collapsible] Most appearance sections start collapsed so
    // the page reads as a short index; expand what you're here for.
    @State private var showPalette = false
    @State private var showWallpaper = false
    @State private var showAvatars = false
    @State private var showIcons = false
    @State private var showThemePack = false
    @State private var showThemeLibrary = false

    /// #5: AI 侧名字跟灵魂名走（不用写死名字）
    @MainActor private var aiName: String {
        let n = SoulStore.cachedMetadata.name
        return n.isEmpty ? "AI" : n
    }

    var body: some View {
        List {
            Section {
                themePreview
            } header: {
                Text("你的房间")
            } footer: {
                Text("默认是安静的暖纸色。下面每一项都可以换，布局不会跟着乱。")
            }

            // [T-appearance-collapsible] 气泡 promoted to its own always-open
            // section — colour + opacity for both bubbles, no digging.
            Section {
                ForEach([AppearanceColorRole.userBubble, .assistantBubble]) { role in
                    HStack(spacing: 12) {
                        ColorPicker(role.title,
                                    selection: studio.colorBinding(role,
                                                                   scope: .global,
                                                                   variant: variant),
                                    supportsOpacity: false)
                        Text("#\(studio.hex(role, scope: .global, variant: variant))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, scope: .global,
                                                          variant: variant))
                    }
                }
                Picker("色盘", selection: $variant) {
                    ForEach(AppearanceVariant.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("气泡透明度")
                        Spacer()
                        Text("\(Int(studio.bubbleOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.bubbleOpacity, in: 0.15...1, step: 0.01)
                }
            } header: {
                Text("气泡")
            } footer: {
                Text("两边聊天气泡的颜色和透明度。形状圆角在「AI 主题包」里。")
            }

            CollapsibleSection(title: "色盘",
                               footer: "这些颜色会流过每一页、卡片、文字、气泡和输入框。浅色和深色会跟着系统外观切换。",
                               isExpanded: $showPalette) {
                Picker("色盘", selection: $variant) {
                    ForEach(AppearanceVariant.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(AppearanceColorRole.allCases.filter { $0 != .userBubble && $0 != .assistantBubble }) { role in
                    HStack(spacing: 12) {
                        ColorPicker(role.title,
                                    selection: studio.colorBinding(role,
                                                                   scope: .global,
                                                                   variant: variant),
                                    supportsOpacity: false)
                        Text("#\(studio.hex(role, scope: .global, variant: variant))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, scope: .global,
                                                          variant: variant))
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(AppearancePreset.allCases) { preset in
                        Button(preset.title) { studio.applyPreset(preset) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("恢复默认色盘", role: .destructive) {
                    studio.resetColors()
                }
            } header: {
                Text("预设")
            }

            CollapsibleSection(title: "AI 主题包",
                               footer: "一整套：色、气泡形状、thinking 卡片图、会话列表、分类图标、壁纸。\(aiName)也可以用 minis-theme 直接贴上来。",
                               isExpanded: $showThemePack) {
                let pack = studio.currentThemePack()
                VStack(alignment: .leading, spacing: 6) {
                    Text(pack.name)
                        .font(.headline)
                    Text("气泡 \(pack.userStyle.title)/\(pack.assistantStyle.title) · thinking \(Int(pack.thinkingRadius))")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText))
                }
                .id(studio.themePackRevision)

                Picker("我的气泡", selection: userStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("\(aiName)气泡", selection: assistantStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("列表图标", selection: listIconShapeBinding) {
                    ForEach(AppearanceListIconShape.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("输入栏形状", selection: inputBarStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Picker("正文字体", selection: fontFamilyBinding) {
                    ForEach(AppearanceFontFamily.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("thinking 标题字")
                        Spacer()
                        Text("\(Int(pack.thinkingTitleSize))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: thinkingTitleSizeBinding, in: 10...22, step: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("thinking 正文字")
                        Spacer()
                        Text("\(Int(pack.thinkingBodySize))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: thinkingBodySizeBinding, in: 10...22, step: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("输入栏圆角")
                        Spacer()
                        Text("\(Int(pack.inputBarRadius))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: inputBarRadiusBinding, in: 4...32, step: 1)
                }

                ForEach(AppearanceThemePack.categoryKeys, id: \.self) { key in
                    let themed = MinisThemeList.categoryIcon(for: key)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: themed.systemName)
                                .foregroundStyle(themed.color)
                                .frame(width: 22)
                            Text(key)
                                .font(.caption)
                            Spacer()
                            PhotosPicker(selection: Binding(
                                get: { categoryImageKey == key ? categoryImageItem : nil },
                                set: { newValue in
                                    categoryImageKey = key
                                    categoryImageItem = newValue
                                }
                            ), matching: .images) {
                                Text(studio.categoryImage(for: key) == nil ? "贴图" : "换图")
                            }
                            if studio.categoryImage(for: key) != nil {
                                Button("还原图") { studio.removeCategoryImage(for: key) }
                                    .foregroundStyle(studio.color(.destructive))
                            }
                        }
                        TextField("SF 名，空着就是默认", text: categorySymbolBinding(key))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.caption, design: .monospaced))
                        HStack {
                            ColorPicker("图标色", selection: categoryColorBinding(key), supportsOpacity: false)
                            if pack.categoryIcons[key] != nil || pack.categoryColors[key] != nil {
                                Button("还原图标") { studio.clearCategoryChrome(for: key) }
                                    .foregroundStyle(studio.color(.destructive))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                PhotosPicker(selection: $thinkingCardItem, matching: .images) {
                    Label(studio.hasThinkingCardImage() ? "更换 thinking 卡片图" : "给 thinking 卡片贴图",
                          systemImage: "photo.on.rectangle")
                }
                if studio.hasThinkingCardImage() {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("卡片图浓度")
                            Spacer()
                            Text("\(Int(pack.thinkingCardImageOpacity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: thinkingCardOpacityBinding, in: 0.05...1, step: 0.01)
                    }
                    Button("去掉 thinking 卡片图", role: .destructive) {
                        studio.removeThinkingCardImage()
                    }
                }

                PhotosPicker(selection: $inputBarItem, matching: .images) {
                    Label(studio.hasInputBarImage() ? "更换输入栏图" : "给输入栏贴图",
                          systemImage: "photo.on.rectangle")
                }
                if studio.hasInputBarImage() {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("输入栏图浓度")
                            Spacer()
                            Text("\(Int(pack.inputBarImageOpacity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: inputBarImageOpacityBinding, in: 0.05...1, step: 0.01)
                    }
                    Button("去掉输入栏图", role: .destructive) {
                        studio.removeInputBarImage()
                    }
                }

                Button("导出当前主题包到剪贴板") {
                    exportPackToClipboard()
                }
                Button("从剪贴板贴上主题包") {
                    importPackFromClipboard()
                }
                Button("恢复默认主题包", role: .destructive) {
                    studio.resetThemePack()
                }
            }

            CollapsibleSection(title: "主题库",
                               footer: "保存是另存一份，不会冲掉正在用的。应用才换上去。最多四十套。",
                               isExpanded: $showThemeLibrary) {
                TextField("给这套起个名字", text: $saveName)
                Button("保存当前主题") {
                    let item = studio.saveCurrentTheme(name: saveName)
                    saveName = ""
                    _ = item
                }
                let saved = studio.savedThemes()
                if saved.isEmpty {
                    Text("还没有存过的主题。")
                        .foregroundStyle(studio.color(.secondaryText))
                } else {
                    ForEach(saved) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.userStyleTitle + " · " + item.assistantStyleTitle)
                                    .font(.caption)
                                    .foregroundStyle(studio.color(.secondaryText))
                            }
                            Spacer()
                            Button("应用") { _ = studio.applySavedTheme(id: item.id) }
                            Button("删", role: .destructive) { _ = studio.deleteSavedTheme(id: item.id) }
                        }
                    }
                }
            }

            CollapsibleSection(title: "页面背景",
                               footer: "可以先给全部页面设一张图，再只换你想单独打扮的那一页。压色保护文字对比；卡片透明度决定图透出来多少。",
                               isExpanded: $showWallpaper) {
                Picker("壁纸用于", selection: $wallpaperScope) {
                    ForEach(AppearanceScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                ZStack(alignment: .bottomTrailing) {
                    AppearanceBackdrop(scope: wallpaperScope)
                    Text(studio.hasWallpaper(wallpaperScope) ? "壁纸预览" : "纯色背景")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(studio.color(.primaryText, scope: wallpaperScope))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(studio.color(.raised, scope: wallpaperScope).opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(10)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(studio.color(.border, scope: wallpaperScope), lineWidth: 0.8)
                )

                PhotosPicker(selection: $wallpaperItem, matching: .images) {
                    Label(studio.hasOwnWallpaper(wallpaperScope) ? "更换这张壁纸" : "选择壁纸",
                          systemImage: "photo")
                }

                if studio.hasOwnWallpaper(wallpaperScope) {
                    Button("改用继承的背景", role: .destructive) {
                        studio.removeWallpaper(wallpaperScope)
                    }
                }

                // [T-wallpaper-clear][09-10 醒醒] Return this page to its
                // initial plain background — drops its own image AND cuts the
                // global inheritance (distinct from 改用继承的背景).
                if studio.hasWallpaper(wallpaperScope) {
                    Button("清除当前背景", role: .destructive) {
                        studio.clearWallpaper(wallpaperScope)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("壁纸压色")
                        Spacer()
                        Text("\(Int(studio.wallpaperShade * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.wallpaperShade, in: 0...0.65, step: 0.01)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("卡片透明度")
                        Spacer()
                        Text("\(Int(studio.surfaceOpacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $studio.surfaceOpacity, in: 0.35...1, step: 0.01)
                }
            }

            CollapsibleSection(title: "情头",
                               footer: "两张图都会裁成方的，存在这台手机上。\(aiName)的头像同时就是 Soul 图标，身份不会各处长不一样。",
                               isExpanded: $showAvatars) {
                pairedAvatarPreview

                PhotosPicker(selection: $userAvatarItem, matching: .images) {
                    Label("选我的头像", systemImage: "person.crop.square")
                }
                if !studio.userAvatar.isEmpty {
                    Button("去掉我的头像", role: .destructive) {
                        studio.removeUserAvatar()
                    }
                }

                PhotosPicker(selection: $assistantAvatarItem, matching: .images) {
                    Label("选\(aiName)的头像", systemImage: "sparkles.rectangle.stack")
                }
                if !SoulStore.cachedMetadata.icon.isEmpty {
                    Button("去掉\(aiName)的头像", role: .destructive) {
                        do { try studio.removeAssistantAvatar() }
                        catch { errorText = error.localizedDescription }
                    }
                }
            }

            CollapsibleSection(title: "图标",
                               footer: "默认图标跟着色盘走，不再用彩虹圆底。不喜欢系统图标，就在这里换成你自己的图。",
                               isExpanded: $showIcons) {
                ForEach(QuietIconSlot.allCases) { slot in
                    HStack(spacing: 12) {
                        QuietAppIcon(id: slot.id, systemName: slot.systemName, size: 28)
                        Text(slot.title)
                        Spacer()
                        PhotosPicker(selection: Binding(
                            get: { iconPickSlot == slot ? iconItem : nil },
                            set: { newValue in
                                iconPickSlot = slot
                                iconItem = newValue
                            }
                        ), matching: .images) {
                            Text(studio.customIcon(for: slot.id) == nil ? "上传" : "更换")
                        }
                        if studio.customIcon(for: slot.id) != nil {
                            Button("还原") {
                                studio.removeIcon(for: slot.id)
                            }
                            .foregroundStyle(studio.color(.destructive))
                        }
                    }
                }
            }
        }
        .appearancePage(.settings)
        .navigationTitle("装扮")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CompactListSections())
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setWallpaper($0, for: wallpaperScope) } }
        }
        .onChange(of: userAvatarItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setUserAvatar($0) } }
        }
        .onChange(of: assistantAvatarItem) { item in
            guard let item else { return }
            Task {
                await importImage(item) { image in
                    do { try studio.setAssistantAvatar(image) }
                    catch { errorText = error.localizedDescription }
                }
            }
        }
        .onChange(of: iconItem) { item in
            guard let item, let slot = iconPickSlot else { return }
            Task {
                await importImage(item) { image in
                    studio.setIcon(image, for: slot.id)
                }
                iconItem = nil
                iconPickSlot = nil
            }
        }
        .onChange(of: thinkingCardItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setThinkingCardImage($0) } }
        }
        .onChange(of: inputBarItem) { item in
            guard let item else { return }
            Task { await importImage(item) { studio.setInputBarImage($0) } }
        }
        .onChange(of: categoryImageItem) { item in
            guard let item, let key = categoryImageKey else { return }
            Task {
                await importImage(item) { studio.setCategoryImage($0, for: key) }
                categoryImageItem = nil
                categoryImageKey = nil
            }
        }
        .alert("这张图用不了", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .listRowBackground(AppearanceStudio.shared.color(.surface, scope: .settings))
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("一间可以慢慢变成你的房间")
                        .font(.headline)
                    Text("默认安静。想打扮时再动手。")
                        .font(.caption)
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                }
                Spacer()
                Circle()
                    .fill(studio.color(.accent, variant: variant))
                    .frame(width: 18, height: 18)
            }
            HStack(spacing: 8) {
                previewSwatch(.surface)
                previewSwatch(.mutedSurface)
                previewSwatch(.userBubble)
                previewSwatch(.assistantBubble)
                previewSwatch(.input)
            }
        }
        .padding(18)
        .foregroundStyle(studio.color(.primaryText, variant: variant))
        .background(studio.color(.surface, variant: variant),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(studio.color(.border, variant: variant), lineWidth: 0.8)
        )
        .listRowBackground(Color.clear)
    }

    private func previewSwatch(_ role: AppearanceColorRole) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(studio.color(role, variant: variant))
            .frame(height: 28)
    }

    private var pairedAvatarPreview: some View {
        HStack(spacing: 12) {
            Spacer()
            VStack(spacing: 6) {
                PersonAvatarView(kind: .assistant, size: 54)
                Text(aiName)
                    .font(.caption)
            }
            Image(systemName: "link")
                .foregroundStyle(studio.color(.accent))
            VStack(spacing: 6) {
                PersonAvatarView(kind: .user, size: 54)
                Text("你").font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @MainActor
    private func importImage(_ item: PhotosPickerItem,
                             apply: @escaping @MainActor (UIImage) -> Void) async {
        defer {
            wallpaperItem = nil
            userAvatarItem = nil
            assistantAvatarItem = nil
            thinkingCardItem = nil
            inputBarItem = nil
            categoryImageItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorText = "选中的图读不出来。"
            return
        }
        apply(image)
    }

    private var userStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(
            get: { studio.currentThemePack().userStyle },
            set: { studio.setBubbleStyle($0, user: true) }
        )
    }

    private var assistantStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(
            get: { studio.currentThemePack().assistantStyle },
            set: { studio.setBubbleStyle($0, user: false) }
        )
    }

    private var thinkingCardOpacityBinding: Binding<Double> {
        Binding(
            get: { studio.currentThemePack().thinkingCardImageOpacity },
            set: { studio.setThinkingCardImageOpacity($0) }
        )
    }

    private var listIconShapeBinding: Binding<AppearanceListIconShape> {
        Binding(
            get: { AppearanceListIconShape.parse(studio.currentThemePack().listIconShape) },
            set: { studio.setListIconShape($0) }
        )
    }

    private var inputBarStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(
            get: { AppearanceBubbleStyle.parse(studio.currentThemePack().inputBarStyle) },
            set: { studio.setInputBarStyle($0) }
        )
    }

    private var fontFamilyBinding: Binding<AppearanceFontFamily> {
        Binding(
            get: { AppearanceFontFamily.parse(studio.currentThemePack().fontFamily) },
            set: { studio.setFontFamily($0) }
        )
    }

    private var inputBarImageOpacityBinding: Binding<Double> {
        Binding(
            get: { studio.currentThemePack().inputBarImageOpacity },
            set: { studio.setInputBarImageOpacity($0) }
        )
    }

    private var thinkingTitleSizeBinding: Binding<Double> {
        Binding(
            get: { studio.currentThemePack().thinkingTitleSize },
            set: { studio.setThinkingFont(title: $0) }
        )
    }

    private var thinkingBodySizeBinding: Binding<Double> {
        Binding(
            get: { studio.currentThemePack().thinkingBodySize },
            set: { studio.setThinkingFont(body: $0) }
        )
    }

    private var inputBarRadiusBinding: Binding<Double> {
        Binding(
            get: { studio.currentThemePack().inputBarRadius },
            set: { studio.setInputBarRadius($0) }
        )
    }

    private func categorySymbolBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { studio.currentThemePack().categoryIcons[key] ?? "" },
            set: { studio.setCategorySymbol($0, for: key) }
        )
    }

    private func categoryColorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: { MinisThemeList.categoryIcon(for: key).color },
            set: { studio.setCategoryColor($0, for: key) }
        )
    }

    private func exportPackToClipboard() {
        let pack = studio.exportThemePack(includeWallpaper: true)
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject(), options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            errorText = "主题包写不出来。"
            return
        }
        UIPasteboard.general.string = text
    }

    private func importPackFromClipboard() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorText = "剪贴板里没有能用的主题包。"
            return
        }
        do {
            let pack = try AppearanceThemePack.decode(obj)
            studio.applyThemePack(pack)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// [T-appearance-collapsible] A Form/List Section that collapses to a single
/// DisclosureGroup row. Content views are built lazily so a collapsed section
/// costs nothing.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                content()
            } label: {
                Text(title)
                    .font(.body.weight(.medium))
            }
        } footer: {
            if let footer, isExpanded {
                Text(footer)
            }
        }
    }
}


/// #11 装扮页 section 紧凑间距。`.listSectionSpacing` 是 iOS 17+ API，
/// 部署目标 16.0 —— 低版本退回默认间距，不炸编译。
private struct CompactListSections: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(.compact)
        } else {
            content
        }
    }
}
