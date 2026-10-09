import SwiftUI
import PhotosUI

/// Settings page for SOUL.md — Minis's persistent personality file.
/// Lives between Skills and Memory in the Agent Runtime section.
struct SoulSettingsView: View {
    @State private var name: String = SoulMetadata.default.name
    /// Raw emoji value loaded from SOUL.md. Not user-editable; preserved
    /// verbatim on save so we don't rewrite a value the user (or another
    /// device) may have set in the file. It is never rendered anywhere.
    @State private var rawEmoji: String = SoulMetadata.default.emoji
    /// [T-soul-custom-icon] The user's identity icon: a relative file
    /// reference (`avatars/….png`), or empty for the default. (A legacy
    /// non-image value is kept on disk but renders as the default.)
    @State private var icon: String = SoulMetadata.default.icon
    @State private var showIconOptions = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var iconError: String? = nil
    @State private var style: String = SoulMetadata.default.style
    @State private var lang: String = SoulMetadata.default.lang
    @State private var bodyText: String = ""
    @State private var saveError: String? = nil
    @State private var didJustSave: Bool = false
    @State private var showRestoreConfirm: Bool = false
    @State private var showForceSyncDone: Bool = false
    @StateObject private var loadedRef = LoadedFileRef()
    /// Mirrors `SyncV2Bootstrap.isEnabled` so the Force iCloud Sync row
    /// shows / hides reactively when the user toggles iCloud sync in
    /// Settings. Same pattern as SkillDetailView (#440 / 3a4fe546).
    @AppStorage("cloudSync.v2.enabled") private var iCloudSyncEnabled: Bool = false

    private static var langOptions: [(label: String, value: String)] {
        [
            (AppLocalized("Auto"), "auto"),
            (AppLocalized("Chinese"), "zh"),
            (AppLocalized("English"), "en"),
        ]
    }

    var body: some View {
        Form {
            Section {
                previewCard
            }

            Section(AppLocalized("Identity")) {
                LabeledContent(AppLocalized("Name")) {
                    TextField("我的小家", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                LabeledContent(AppLocalized("Style")) {
                    TextField(AppLocalized("e.g. Warm, direct, opinionated"), text: $style)
                        .multilineTextAlignment(.trailing)
                }
                Picker(AppLocalized("Language"), selection: $lang) {
                    ForEach(Self.langOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            }

            Section {
                personalityEditor
            } header: {
                Text(AppLocalized("Personality Prompt"))
            } footer: {
                bodyLengthFooter
            }

            Section {
                Button(role: .destructive) {
                    showRestoreConfirm = true
                } label: {
                    Label(AppLocalized("Restore Default"), systemImage: "arrow.uturn.backward")
                }

                // Force iCloud Sync — re-marks SOUL.md dirty and asks
                // SyncCore to send immediately. Same gating predicate
                // as SkillDetailView (47fd61ef / 3a4fe546): hidden
                // entirely when the user has iCloud sync off, since
                // the action would no-op on a disabled engine.
                if #available(iOS 17.0, *), iCloudSyncEnabled {
                    Button {
                        Task { await forceSyncSoul() }
                    } label: {
                        HStack {
                            Label(AppLocalized("Force iCloud Sync"), systemImage: "icloud.and.arrow.up")
                            Spacer()
                            if showForceSyncDone {
                                Text(AppLocalized("Queued"))
                                    .foregroundStyle(MinisTheme.success)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(MinisTheme.destructive)
                }
            }
        }
        .navigationTitle(AppLocalized("Soul"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalized("Save")) { save() }
                    .disabled(!isDirty)
            }
        }
        .onAppear(perform: reload)
        // Using .alert (not .confirmationDialog) so the dialog stays
        // centered on iPad / Mac. confirmationDialog without a source
        // rect renders as a popover anchored to the screen's top edge
        // on regular-width size classes.
        .alert(
            AppLocalized("Restore Default"),
            isPresented: $showRestoreConfirm
        ) {
            Button(AppLocalized("Restore Default"), role: .destructive, action: restoreDefault)
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Restore default SOUL.md? Your current personality will be replaced."))
        }
        .modifier(SoulIconEditing(
            icon: $icon,
            showPhotoPicker: $showPhotoPicker,
            photoItem: $photoItem,
            iconError: $iconError
        ))
        .overlay(alignment: .bottom) {
            if didJustSave {
                Text(AppLocalized("Saved"))
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(MinisTheme.success.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .settingsPage()
    }

    // MARK: - Subviews

    // Standard Form row — the insetGrouped section provides the rounded
    // card chrome automatically, so we only render content here. Matches
    // the visual width of every other section on the page.
    private var previewCard: some View {
        HStack(alignment: .center, spacing: 12) {
            // [T-soul-custom-icon] Tappable, and it has to LOOK tappable: a
            // bare glyph sitting on the card reads as decoration, and the
            // pencil badge alone was too easy to miss. A filled circle gives
            // the icon a defined edge and a hit area the eye can find, which
            // is the same treatment the category badges elsewhere in Settings
            // use. It doubles as a backdrop for transparent PNG icons, whose
            // whole point is having no background of their own.
            Button {
                showIconOptions = true
            } label: {
                // Inset inside the 52pt button so the grey disc stays visible
                // as a ring even when the icon is an image, which otherwise
                // fills the whole frame and hides the affordance entirely.
                SoulIconView(icon: icon, size: SoulIconImage.renderPoints)
                    .frame(width: 44, height: 44)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .overlay(
                        Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                    // The badge sits INSIDE the circle's bounds rather than
                    // straddling its edge. Overhanging it (even with padding)
                    // gets clipped to a sliver by the enclosing Button label,
                    // which is what made the pencil hard to see.
                    //
                    // Drawn as an explicit filled Circle + pencil glyph rather
                    // than `pencil.circle.fill` with .palette: that symbol's
                    // "circle" layer is the BACKGROUND, so on the white card it
                    // rendered as an invisible disc with a bare diagonal stroke
                    // floating over it. Compositing it ourselves also lets the
                    // badge keep a contrasting ring against a dark icon image.
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(MinisTheme.accent))
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 1, y: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalized("Change icon"))
            // [T-soul-custom-icon] Attached to the BUTTON, not to the whole
            // page. A confirmationDialog anchors its popover to the view it
            // is attached to, so hanging it off the Form (as this first did)
            // pointed the arrow at the middle of the page — visibly at the
            // Style row — instead of at the icon the user tapped. Only the
            // dialog needs the anchor; the alerts and the photo picker are
            // centered/full-screen and stay at page level.
            .confirmationDialog(AppLocalized("Change icon"), isPresented: $showIconOptions) {
                Button(AppLocalized("Choose Image…")) { showPhotoPicker = true }
                if !icon.isEmpty {
                    Button(AppLocalized("Use Default"), role: .destructive) { icon = "" }
                }
                Button(AppLocalized("Cancel"), role: .cancel) {}
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "我的小家" : name)
                    .font(.title3.weight(.semibold))
                if !style.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(style)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var personalityEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $bodyText)
                .frame(minHeight: 220)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
            // SwiftUI's TextEditor has no native placeholder. We render
            // a greyed hint on top when the body is empty + not being
            // typed into. allowsHitTesting(false) so taps fall through
            // to the editor below.
            if bodyText.isEmpty {
                Text(AppLocalized("Describe the personality and voice you want for your agent"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Footer under the personality editor. Shows a live token count
    /// (informational only — the hard cap was removed, so there is no
    /// over-limit state to render any more).
    private var bodyLengthFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.justify.left")
                .foregroundStyle(.secondary)
            Text(soulBodyCountText(bodyText))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    /// Counter shown when the body is within budget.
    private func soulBodyCountText(_ body: String) -> String {
        let count = SoulStore.tokenCount(body)
        return AppLocalized("\(count) tokens")
    }

    // MARK: - Persistence

    private var currentFile: SoulFile {
        SoulFile(
            metadata: SoulMetadata(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                // Round-trip the on-disk emoji untouched — UI no longer
                // edits this field, but a SOUL.md authored elsewhere
                // (other device / hand-edit) should not have its emoji
                // rewritten on save.
                emoji: rawEmoji,
                style: style,
                lang: lang,
                icon: icon
            ),
            body: bodyText
        )
    }

    private var isDirty: Bool {
        currentFile != loadedRef.value
    }

    private func reload() {
        let file = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        name = file.metadata.name
        rawEmoji = file.metadata.emoji
        icon = file.metadata.icon
        style = file.metadata.style
        lang = file.metadata.lang
        bodyText = file.body
        loadedRef.value = file
        saveError = nil
    }

    private func save() {
        do {
            let f = currentFile
            try SoulStore.save(f)
            loadedRef.value = f
            saveError = nil
            withAnimation { didJustSave = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { didJustSave = false }
            }
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Bidirectional Soul sync: push local SOUL.md up and pull the
    /// latest remote SoulV2 down. Mirrors `ProviderInstancesView`'s
    /// Force iCloud Sync entry (which uses the same `bidirectionalSync`
    /// helper). iOS-17 gated because the v2 sync surface is.
    @available(iOS 17.0, *)
    @MainActor
    private func forceSyncSoul() async {
        // 1. Re-mark local SOUL.md dirty (if present) so the upload
        //    side ships our copy.
        _ = await ForceSyncHelper.markSoulDirty()
        // 2. Run a full sendNow + fullFetchAndReconcile cycle so any
        //    peer-newer SoulV2 lands and the merger overwrites local
        //    via SoulStore.applyRemoteContent (LWW by mtime).
        await ForceSyncHelper.bidirectionalSync(recordTypes: ["SoulV2"])
        // 3. Re-read the on-disk file in case the merger just replaced
        //    it with a peer's newer copy — otherwise the form stays
        //    showing the pre-sync values.
        reload()
        showForceSyncDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showForceSyncDone = false }
    }

    private func restoreDefault() {
        let parsed = SoulMDParser.parse(SoulStore.defaultContent)
        name = parsed.metadata.name
        rawEmoji = parsed.metadata.emoji
        // The default content carries no icon, so this resets to "" (default
        // presentation). Omitting it left the custom icon in place AND let
        // the save() below write it into the "restored" file permanently.
        icon = parsed.metadata.icon
        style = parsed.metadata.style
        lang = parsed.metadata.lang
        bodyText = parsed.body
        save()
    }

    private final class LoadedFileRef: ObservableObject {
        var value: SoulFile = SoulFile(metadata: .default, body: "")
    }
}

/// [T-soul-custom-icon] The icon picker's presentation chain, lifted out of
/// `SoulSettingsView.body`.
///
/// Not a style choice: inlining these four presentation modifiers pushed the
/// `body` expression past what the type-checker will solve ("unable to
/// type-check this expression in reasonable time"). A ViewModifier gives the
/// solver a fresh, small expression to work on.
private struct SoulIconEditing: ViewModifier {
    @Binding var icon: String
    @Binding var showPhotoPicker: Bool
    @Binding var photoItem: PhotosPickerItem?
    @Binding var iconError: String?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                          matching: .images, photoLibrary: .shared())
            // Single-parameter form: the two-parameter `onChange` is iOS 17+,
            // and this target still deploys lower.
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await applyPickedImage(newItem) }
            }
            .alert(AppLocalized("Can't use that image"),
                   isPresented: Binding(get: { iconError != nil },
                                        set: { if !$0 { iconError = nil } })) {
                Button(AppLocalized("OK"), role: .cancel) { iconError = nil }
            } message: {
                Text(iconError ?? "")
            }
    }

    /// Load, validate and normalize a picked photo into the stored form.
    private func applyPickedImage(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        // [PIC-4] Downsample-decode to the stored 512px cap instead of
        // expanding the full photo first (same treatment as the
        // Appearance studio picker).
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else {
            await MainActor.run { iconError = AppLocalized("That image couldn't be read.") }
            return
        }
        // [T-soul-icon-opaque-rounded] Opaque images are accepted now — the
        // transparency requirement was a presentation concern and moved to
        // `SoulIconView`, which clips every image to a rounded rectangle.
        // store() applies no size limit, so a large photo is never refused.
        // The avatar lands in Application Support/avatars/; SOUL.md keeps
        // only the relative path.
        let name = SoulIconImage.storedName(prefix: "soul", id: PersonaStore.currentID())
        switch SoulIconImage.store(image, named: name) {
        case .success(let path):
            await MainActor.run { icon = path }
        case .failure(.unreadable):
            await MainActor.run {
                iconError = AppLocalized("That image couldn't be read.")
            }
        }
    }
}
