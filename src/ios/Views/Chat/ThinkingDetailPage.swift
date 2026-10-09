import SwiftUI

// MARK: - Thinking Detail Page (nested mode)

///
/// [T-nested-ui] Detail page pushed when a thinking summary row is tapped.
/// Shows the full thinking content plus the tool calls that followed it as
/// nested tappable rows — each pushes its own tool detail page, so nesting
/// can go multiple levels deep. Back button pops one level.
///
/// Background follows the drawer's visual identity: the user's customizable
/// thinking-card image at their chosen opacity (theme fallback when unset).
/// [T-theme-no-hardcode] All colors from theme tokens, all sizes from the
/// theme pack. No hardcoded colors, no emoji.
struct ThinkingDetailPage: View {
    @ObservedObject var block: AssistantBlock
    /// Tool blocks that come after this thinking block in the same message.
    let toolsAfter: [AssistantBlock]
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?

    /// One-liner for a nested tool row: LLM summary if present, else the
    /// tool's description.
    private func toolRowText(for toolBlock: AssistantBlock) -> String {
        if let s = toolBlock.toolSummary, !s.isEmpty { return s }
        return toolBlock.toolDescription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Full thinking content.
                if !block.content.isEmpty {
                    Text(block.content)
                        .font(.system(size: MinisThemeShape.thinkingBodySize))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                // Nested tool rows — tap pushes the tool detail page.
                if !toolsAfter.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLocalized("Tool Calls"))
                            .font(.system(size: MinisThemeShape.thinkingTitleSize, weight: .semibold))
                            .foregroundStyle(ChatColors.secondaryText)
                            .padding(.horizontal, 16)

                        ForEach(toolsAfter) { toolBlock in
                            NavigationLink {
                                ToolLiveSheet(
                                    toolBlocks: [toolBlock],
                                    initialIdx: 0,
                                    toolSnapshots: toolSnapshots,
                                    browserPool: browserPool,
                                    onBrowserTakeover: onBrowserTakeover,
                                    onTakeoverDone: onTakeoverDone
                                )
                                .navigationTitle(AppLocalized("Tool Detail"))
                                .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 14))
                                        .foregroundStyle(ChatColors.secondaryText)
                                    Text(toolRowText(for: toolBlock))
                                        .font(.system(size: MinisThemeShape.thinkingTitleSize))
                                        .foregroundStyle(ChatColors.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(ChatColors.tertiaryText)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: AssistantBlockView.nestedInlineHeight)
                                .nestedDrawerBackground()
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .background {
            // [T-nested-ui] Detail page background = the thinking-card image,
            // same as the drawer — the image follows the content.
            if let uiImage = MinisThemeShape.pack.thinkingCardImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(MinisThemeShape.pack.thinkingCardImageOpacity)
                    .ignoresSafeArea()
            } else {
                ChatColors.background.ignoresSafeArea()
            }
        }
        .navigationTitle(AppLocalized("Thinking"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
