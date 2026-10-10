import SwiftUI

// MARK: - Turn Detail Sheet
//
// The turn drawer: native bottom sheet content, 1:1 from
// thinking-drawer-mockup.html. Header has exactly ONE button top-left
// (X at top level, ‹ when nested) + centered title. Body is a timeline
// (gray dots + 1pt lines; thinking/tool rows tappable) or a detail page
// (plain text: small gray label + content). Browser rows embed the existing
// MinisLinkPreviewView; shell rows embed ShellOutputView. Sheet background
// is the thinking card token. The X button is a white circle per the mockup.

struct TurnDetailSheet: View {
    @ObservedObject var message: ChatMessage
    var browserPool: BrowserTabPool?
    var onExpandBrowser: ((URL) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Navigation stack of detail blocks; empty = timeline top level.
    @State private var navStack: [AssistantBlock] = []

    /// Thinking/tool blocks in turn order — everything the summary row
    /// swallowed, all reachable here.
    private var timelineBlocks: [AssistantBlock] {
        message.blocks.filter { $0.kind == .thinking || $0.kind.isToolKind }
    }

    private var title: String {
        if let block = navStack.last {
            return detailTitle(for: block)
        }
        return AppLocalized("Summary")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if let block = navStack.last {
                    detailPage(for: block)
                } else {
                    timeline
                }
            }
        }
        .background(thinkingBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                if navStack.isEmpty {
                    dismiss()
                } else {
                    navStack.removeLast()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(ChatColors.secondaryBg)
                        .frame(width: 38, height: 38)
                        .shadow(color: ChatColors.primaryText.opacity(0.08), radius: 5, x: 0, y: 1)
                    Text(navStack.isEmpty ? "✕" : "‹")
                        .font(.system(size: 21))
                        .foregroundStyle(ChatColors.primaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("turnSheetHeaderButton")

            Spacer()

            Text(title)
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16), weight: .bold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)

            Spacer()

            // Balances the 38pt button so the title is truly centered.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.init(top: 6, leading: 14, bottom: 10, trailing: 14))
    }

    private var thinkingBackground: some View {
        ZStack {
            MinisThemeShape.thinkingFill
            if let image = AppearanceStudio.shared.thinkingCardImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(MinisThemeShape.thinkingCardOpacity)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(Array(timelineBlocks.enumerated()), id: \.element.id) { idx, block in
                timelineRow(for: block)
                if idx < timelineBlocks.count - 1 {
                    // 1pt connecting line, aligned under the dot.
                    Rectangle()
                        .fill(ChatColors.secondaryText.opacity(0.25))
                        .frame(width: 1, height: 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 3 + 4)
                }
            }
        }
        .padding(.init(top: 4, leading: 20, bottom: 4, trailing: 20))
    }

    private func timelineRow(for block: AssistantBlock) -> some View {
        Button {
            navStack.append(block)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if block.kind == .thinking {
                    Circle()
                        .fill(ChatColors.secondaryText)
                        .frame(width: 8, height: 8)
                        .padding(.top, 7)
                } else {
                    toolIcon(for: block.kind)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(ChatColors.secondaryText)
                        .frame(width: 20, height: 20)
                        .padding(.top, 2)
                }
                Text(timelineText(for: block))
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(14.5)))
                    .foregroundStyle(block.kind == .thinking ? ChatColors.primaryText : ChatColors.secondaryText)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(ChatColors.secondaryText)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("turnTimelineRow")
    }

    private func timelineText(for block: AssistantBlock) -> String {
        if block.kind == .thinking {
            let firstLine = block.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let short = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
            if short.isEmpty { return AppLocalized("Thought for a while") }
            return AppLocalized("Thinking: \(short)")
        }
        return block.toolDescription.isEmpty ? toolKindName(for: block.kind) : block.toolDescription
    }

    // MARK: - Detail pages

    private func detailTitle(for block: AssistantBlock) -> String {
        switch block.kind {
        case .thinking:
            return AppLocalized("Thinking Process")
        case .browserTool:
            return AppLocalized("Browser")
        case .shellTool:
            return AppLocalized("Shell")
        default:
            return toolKindName(for: block.kind)
        }
    }

    @ViewBuilder
    private func detailPage(for block: AssistantBlock) -> some View {
        switch block.kind {
        case .browserTool:
            if let url = resolvedBrowserURL(for: block) {
                MinisLinkPreviewView(
                    url: url,
                    browserPool: browserPool,
                    onExpand: onExpandBrowser == nil ? nil : { _ in
                        let target = url
                        dismiss()
                        // Let the drawer dismiss before opening the full browser.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            onExpandBrowser?(target)
                        }
                    }
                )
            } else {
                plainDetail(label: AppLocalized("Browser"), content: block.toolDescription)
            }
        case .shellTool:
            ShellOutputView(
                block: block,
                isLive: false,
                accentColor: ChatColors.accent,
                cardMinHeight: 0
            )
            .padding(.horizontal, 8)
        case .thinking:
            plainDetail(label: AppLocalized("Full thinking"), content: block.content)
        default:
            plainDetail(label: toolKindName(for: block.kind), content: block.content)
        }
    }

    /// Plain-text detail: small gray label + content. No cards, no panels.
    private func plainDetail(label: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(12)))
                .foregroundStyle(ChatColors.secondaryText)
            if !content.isEmpty {
                Text(content)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(14)))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.init(top: 10, leading: 22, bottom: 10, trailing: 22))
    }

    // MARK: - Helpers

    private func toolIcon(for kind: AssistantBlockKind) -> Image {
        switch kind {
        case .shellTool: Image(systemName: "terminal")
        case .fileReadTool: Image(systemName: "doc.text")
        case .fileWriteTool: Image(systemName: "doc.text.fill")
        case .fileEditTool: Image(systemName: "square.and.pencil")
        case .browserTool: Image(systemName: "globe")
        case .readImageTool: Image(systemName: "photo")
        case .memoryTool: Image(systemName: "brain.head.profile")
        case .askUserTool: Image(systemName: "questionmark.circle")
        case .thinking: Image("ThinkingIcon")
        case .text: Image(systemName: "text.alignleft")
        case .info: Image(systemName: "arrow.triangle.2.circlepath")
        }
    }

    private func toolKindName(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return AppLocalized("Shell")
        case .fileReadTool: return AppLocalized("File read")
        case .fileWriteTool: return AppLocalized("File write")
        case .fileEditTool: return AppLocalized("File edit")
        case .browserTool: return AppLocalized("Browser")
        case .readImageTool: return AppLocalized("Image read")
        case .memoryTool: return AppLocalized("Memory")
        case .askUserTool: return AppLocalized("Question")
        case .thinking: return AppLocalized("Thinking")
        case .text: return AppLocalized("Text")
        case .info: return AppLocalized("Info")
        }
    }

    /// Resolve the browser URL for a block: block.browserURL, then the `url`
    /// field of toolInputArgs, then inherited from the nearest preceding
    /// browser block with a URL.
    private func resolvedBrowserURL(for block: AssistantBlock) -> URL? {
        if let s = block.browserURL, !s.isEmpty, let url = URL(string: s) { return url }
        if let url = urlFromArgs(block) { return url }
        let blocks = message.blocks
        if let idx = blocks.firstIndex(where: { $0.id == block.id }), idx > 0 {
            for prev in blocks[..<idx].reversed() {
                guard case .browserTool = prev.kind else { continue }
                if let s = prev.browserURL, !s.isEmpty, let url = URL(string: s) { return url }
                if let url = urlFromArgs(prev) { return url }
                break
            }
        }
        return nil
    }

    private func urlFromArgs(_ block: AssistantBlock) -> URL? {
        guard let json = block.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = dict["url"] as? String, !s.isEmpty,
              let url = URL(string: s) else { return nil }
        return url
    }
}
