import SwiftUI

// MARK: - Turn Detail Sheet (custom bottom sheet)
//
// [T-turn-summary-row] Bottom sheet opened by tapping the turn summary row.
// Matches the Claude reference screenshot + user refinements:
// - White sheet, rounded top corners, grabber handle
// - ONE button top-left: X (closes sheet) morphs to ‹ (back one level) when
//   drilled into a tool's detail. Never both.
// - Tap-outside (dimmed scrim) dismisses the whole sheet.
// - Content = vertical timeline: gray dot + step text, 1pt vertical
//   connector line.
// - THINKING entries: shown INLINE as gray text (not tappable, no chevron,
//   no separate detail view) — no matter how long the thinking is.
// - TOOL entries: icon + result text + chevron (tappable). Browser tools
//   open minis's NATIVE browser display (via notification → AIChatView's
//   safariURL → MinisLinkPreviewView); other tools show inline detail.
//
// [T-theme-no-hardcode] ALL colors/sizes from theme tokens.

extension Notification.Name {
    /// Posted when a browser tool entry in the turn sheet is tapped.
    /// AIChatView observes this and opens the native browser preview.
    static let openBrowserURLFromDrawer = Notification.Name("openBrowserURLFromDrawer")
}

struct TurnDetailSheet: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    var toolSnapshots: [ToolSnapshotItem] = []
    var onClose: () -> Void

    /// Drilled-in tool block (nil = root timeline). The top-left button
    /// morphs: X when nil (close sheet), ‹ when non-nil (back to timeline).
    @State private var detailBlock: AssistantBlock?

    /// [T-sheet-detents] Sheet detent: 2/3 screen by default, fullscreen when
    /// expanded. Drag the grabber up to expand, down to collapse/dismiss.
    @State private var isExpanded = false

    @GestureState private var dragOffset: CGFloat = 0

    /// Thinking + tool blocks in order — the timeline entries.
    private var timelineBlocks: [AssistantBlock] {
        message.blocks.filter { $0.kind == .thinking || $0.kind.isToolKind }
    }

    private var sheetHeight: CGFloat {
        let screenH = UIScreen.main.bounds.height
        return isExpanded ? screenH * 0.95 : screenH * 2 / 3
    }

    private var title: String {
        if let block = detailBlock {
            if block.kind == .thinking {
                return AppLocalized("Thinking")
            }
            return AppLocalized("Tool Detail")
        }
        if let s = message.turnSummary, !s.isEmpty, s.count <= 20 {
            return s
        }
        return AppLocalized("Summary")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grabber — drag up to expand to fullscreen, down to
            // collapse/dismiss. Standard iOS sheet detent behavior.
            Capsule()
                .fill(ChatColors.tertiaryText.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.height
                        }
                        .onEnded { value in
                            let dy = value.translation.height
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if isExpanded {
                                    // Expanded: drag down collapses to 2/3.
                                    if dy > 100 { isExpanded = false }
                                } else {
                                    // 2/3: drag up expands, drag down dismisses.
                                    if dy < -80 { isExpanded = true }
                                    else if dy > 120 { onClose() }
                                }
                            }
                        }
                )

            // Header: morphing button (left) + centered title.
            HStack {
                Button {
                    if detailBlock != nil {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            detailBlock = nil
                        }
                    } else {
                        onClose()
                    }
                } label: {
                    Image(systemName: detailBlock != nil ? "chevron.left" : "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .frame(width: 38, height: 38)
                        .background(ChatColors.secondaryBg)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(detailBlock != nil ? AppLocalized("Back") : AppLocalized("Close")))

                Spacer()

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(1)

                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Content: timeline or drilled-in detail.
            // [T-sheet-size] Adaptive height, capped at 1/3 of screen.
            if let block = detailBlock {
                detailContent(for: block)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(timelineBlocks.enumerated()), id: \.element.id) { index, block in
                            timelineEntry(for: block, isLast: index == timelineBlocks.count - 1)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // [T-sheet-detents] Fixed detents: 2/3 screen, or fullscreen when
        // expanded. Drag the grabber to switch.
        .frame(height: sheetHeight)
        .background(sheetBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .offset(y: dragOffset)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .id(appearanceStudio.themePackRevision)
    }

    private var sheetBackground: some View {
        Group {
            if let uiImage = MinisThemeShape.pack.thinkingCardImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(MinisThemeShape.pack.thinkingCardImageOpacity)
            } else {
                // [T-sheet-bg] Theme's thinking card color — never white.
                MinisThemeShape.pack.thinkingFill(opacity: 1.0)
            }
        }
    }

    // MARK: - Timeline entries

    @ViewBuilder
    private func timelineEntry(for block: AssistantBlock, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if block.kind == .thinking {
                // [T-turn-summary-row] Thinking entry: tappable row (chevron)
                // opening the full thinking content one level deeper.
                // Thinking never gets its own row on the CHAT screen — only
                // here inside the sheet.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        detailBlock = block
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(ChatColors.secondaryText)
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)

                        Text(AppLocalized("Thinking"))
                            .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText)

                        Spacer(minLength: 4)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ChatColors.tertiaryText)
                            .padding(.top, 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(AppLocalized("View full thinking")))
            } else {
                // Dot + description row.
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(ChatColors.secondaryText)
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)

                    timelineDescription(for: block)
                }
            }

            if !isLast {
                connectorLine
            }

            // Tool result row — tappable (browser opens native view).
            if block.kind.isToolKind {
                toolRow(for: block)
                if !isLast {
                    connectorLine
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var connectorLine: some View {
        Rectangle()
            .fill(ChatColors.tertiaryText.opacity(0.5))
            .frame(width: 1, height: 14)
            .padding(.leading, 14.5)
    }

    @ViewBuilder
    private func timelineDescription(for block: AssistantBlock) -> some View {
        switch block.kind {
        case .thinking:
            Text(AppLocalized("Thinking"))
                .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .medium))
                .foregroundStyle(ChatColors.primaryText)
        default:
            Text(block.toolDescription.isEmpty ? toolName(for: block.kind) : block.toolDescription)
                .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                .foregroundStyle(ChatColors.primaryText)
        }
    }

    @ViewBuilder
    private func toolRow(for block: AssistantBlock) -> some View {
        let isBrowser: Bool = {
            if case .browserTool = block.kind { return true }
            return false
        }()
        Button {
            if isBrowser {
                openBrowserNative(for: block)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    detailBlock = block
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: AssistantBlockView.toolCapsuleIcon(for: block.kind))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                    .frame(width: 24, height: 24)

                Text(toolResultLine(for: block))
                    .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(2)

                Spacer(minLength: 4)

                Image(systemName: isBrowser ? "arrow.up.right.square" : "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.leading, 19)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(isBrowser ? AppLocalized("Open in browser") : AppLocalized("View details")))
    }

    /// [T-turn-summary-row] Browser tools reuse minis's NATIVE browser display
    /// exactly as-is: post a notification, AIChatView sets safariURL, the
    /// existing MinisLinkPreviewView sheet opens. No custom browser UI here.
    private func openBrowserNative(for block: AssistantBlock) {
        guard let url = browserURL(from: block) else { return }
        // Close this sheet first so the browser preview isn't stacked under it.
        onClose()
        // Small delay so the dismiss animation doesn't fight the present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openBrowserURLFromDrawer, object: url)
        }
    }

    private func browserURL(from block: AssistantBlock) -> URL? {
        // URL from tool input args JSON.
        if let args = block.toolInputArgs,
           let data = args.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlStr = obj["url"] as? String,
           let url = URL(string: urlStr),
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        // Fallback: first http(s) URL in the result text.
        let text = block.content
        if let range = text.range(of: #"https?://[^\s\"']+"#, options: .regularExpression) {
            return URL(string: String(text[range]))
        }
        return nil
    }

    // MARK: - Drilled-in detail (thinking or tool)

    @ViewBuilder
    private func detailContent(for block: AssistantBlock) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if block.kind == .thinking {
                    // Full thinking content — sits directly on the
                    // thinking image/color with subtle translucency.
                    Text(block.content.isEmpty ? AppLocalized("No thinking content") : block.content)
                        .font(.system(size: 14))
                        .foregroundStyle(ChatColors.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(ChatColors.primaryText.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    if let args = block.toolInputArgs, !args.isEmpty {
                        detailCard(title: AppLocalized("Input"), text: args)
                    }
                    if !block.content.isEmpty {
                        detailCard(title: AppLocalized("Output"), text: String(block.content.prefix(4000)))
                    } else {
                        detailCard(title: AppLocalized("Status"), text: toolResultLine(for: block))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    /// Drilled-in tool detail (kept for reference; use detailContent).
    @ViewBuilder
    private func toolDetailContent(for block: AssistantBlock) -> some View {
        detailContent(for: block)
    }

    private func detailCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ChatColors.primaryText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // [T-sheet-bg] No solid cards — subtle translucency only, content
        // sits directly on the thinking image/color.
        .background(ChatColors.primaryText.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func toolResultLine(for block: AssistantBlock) -> String {
        let result = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            return String(result.prefix(100))
        }
        switch block.toolStatus {
        case .success: return AppLocalized("Completed")
        case .failed(let m): return m.isEmpty ? AppLocalized("Failed") : m
        case .cancelled: return AppLocalized("Cancelled")
        case .running, .streaming: return AppLocalized("Running…")
        case .none: return AppLocalized("Done")
        }
    }

    private func toolName(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return "shell"
        case .fileReadTool: return AppLocalized("Read file")
        case .fileWriteTool: return AppLocalized("Write file")
        case .fileEditTool: return AppLocalized("Edit file")
        case .browserTool: return AppLocalized("Browse web")
        case .readImageTool: return AppLocalized("View image")
        case .memoryTool: return AppLocalized("Memory")
        case .askUserTool: return AppLocalized("Ask user")
        case .text, .thinking, .info: return ""
        }
    }
}
