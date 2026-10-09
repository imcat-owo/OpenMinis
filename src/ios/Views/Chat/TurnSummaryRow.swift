import SwiftUI

// MARK: - Turn Summary Row (one row per turn)
//
// [T-turn-summary-row] The chat shows exactly ONE floating minimal row per
// assistant turn that involved thinking/tools — never two cards/rows for the
// same turn. Everything else lives inside the bottom sheet.
//
// Matches the Claude reference screenshot: a floating single row directly on
// the chat background — small outlined SF Symbol icon (gray) + gray summary
// text + small chevron. NO card background, NO border, NO heavy chrome.
//
// The summary text is the AI-generated one-sentence summary
// (`message.turnSummary`), produced after the turn completes. While the turn
// is working, the row shows a working state ("思考中…" + bouncing dots).
//
// [T-theme-no-hardcode] ALL colors/sizes come from theme tokens:
// `ChatColors.secondaryText` / `.tertiaryText` (theme `.secondaryText`),
// font sizes from `MinisThemeShape.thinkingTitleSize`. The thinking-card
// image background is used ONLY when the user has set one
// (`thinkingCardImage()`); otherwise the row is fully transparent. Even when
// set, it stays subtle.

/// Uniform height for the turn summary row — a single floating line.
extension TurnSummaryRow {
    static let rowHeight: CGFloat = 44
}

struct TurnSummaryRow: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    var onTap: () -> Void

    @State private var dotsActive = false

    /// True while this turn is still working (thinking streaming or a tool
    /// running) — the row shows the working state instead of a summary.
    private var isWorking: Bool {
        if message.turnSummary != nil { return false }
        return message.blocks.contains { block in
            if block.kind == .thinking {
                // Thinking with buffered-but-unflushed content is streaming;
                // content without a summary means the turn isn't done yet.
                if !block.thinkingContentBuffer.isEmpty { return true }
                return !block.content.isEmpty && block.summary == nil
            }
            if block.kind.isToolKind {
                if case .running = block.toolStatus { return true }
                if case .streaming = block.toolStatus { return true }
            }
            return false
        }
    }

    private var summaryText: String {
        if let s = message.turnSummary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if isWorking {
            return AppLocalized("Thinking…")
        }
        // Fallback: describe what happened from block kinds.
        let toolCount = message.blocks.filter { $0.kind.isToolKind }.count
        let hasThinking = message.blocks.contains { $0.kind == .thinking }
        if toolCount > 0 && hasThinking {
            return AppLocalized("Thought and used tools")
        } else if toolCount > 0 {
            return AppLocalized("Used tools")
        } else {
            return AppLocalized("Deep Thinking")
        }
    }

    /// Icon for the row: brain for thinking-heavy turns, wrench for
    /// tool-heavy turns. Outlined SF Symbol, gray like Claude.
    private var iconName: String {
        let toolCount = message.blocks.filter { $0.kind.isToolKind }.count
        let hasThinking = message.blocks.contains { $0.kind == .thinking }
        if hasThinking && toolCount == 0 { return "brain.head.profile" }
        if toolCount > 0 && !hasThinking { return "wrench.and.screwdriver" }
        return "brain.head.profile"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                    .frame(width: 22, height: 22)

                Text(summaryText)
                    .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .regular))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isWorking {
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
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.horizontal, 4)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .background {
                // Thinking-card image ONLY when the user set one; otherwise
                // fully transparent (floating on chat background like Claude).
                // Kept subtle even when set.
                if let uiImage = MinisThemeShape.pack.thinkingCardImage() {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(MinisThemeShape.pack.thinkingCardImageOpacity * 0.45)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .buttonStyle(.plain)
        .id(appearanceStudio.themePackRevision)
        .accessibilityLabel(Text(summaryText))
        .accessibilityHint(Text(AppLocalized("Tap to view details")))
    }
}
