import SwiftUI

// MARK: - Block Detail Root (nested mode)

///
/// [T-nested-ui] Root of the pushed detail NavigationStack. Routes by block
/// kind: thinking blocks get the ThinkingDetailPage (full text + nested tool
/// rows), tool blocks get the ToolLiveSheet as a pushed page. The
/// NavigationStack's back button pops one level; nested NavigationLinks push
/// deeper.
struct BlockDetailRoot: View {
    @ObservedObject var block: AssistantBlock
    let message: ChatMessage
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?

    /// Tool blocks after this thinking block in the same message — the
    /// nested rows on the thinking detail page.
    private var toolsAfterThinking: [AssistantBlock] {
        guard block.kind == .thinking,
              let idx = message.blocks.firstIndex(where: { $0.id == block.id })
        else { return [] }
        return Array(message.blocks[(idx + 1)...]).filter { $0.kind.isToolKind }
    }

    var body: some View {
        Group {
            if block.kind == .thinking {
                ThinkingDetailPage(
                    block: block,
                    toolsAfter: toolsAfterThinking,
                    toolSnapshots: toolSnapshots,
                    browserPool: browserPool,
                    onBrowserTakeover: onBrowserTakeover,
                    onTakeoverDone: onTakeoverDone
                )
            } else {
                // Tool detail as a pushed page (was a bottom sheet).
                let toolBlocks = message.blocks.filter { $0.toolStatus != nil }
                ToolLiveSheet(
                    toolBlocks: toolBlocks,
                    initialIdx: toolBlocks.firstIndex(where: { $0.id == block.id }) ?? 0,
                    toolSnapshots: toolSnapshots,
                    browserPool: browserPool,
                    onBrowserTakeover: onBrowserTakeover,
                    onTakeoverDone: onTakeoverDone
                )
                .navigationTitle(AppLocalized("Tool Detail"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
