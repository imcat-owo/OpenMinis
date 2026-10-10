import SwiftUI

// MARK: - Turn Summary Segments (shared grouping logic)
//
// ONE UNIFIED PATH: both the collection-view snapshot builder
// (CollectionViewMessageListV3.applySnapshot) and the SwiftUI row
// (ChatMessageRow.assistantRow) funnel thinking/tool blocks through this
// helper. A "thinking/tool run" is a maximal run of consecutive blocks whose
// kind is .thinking or whose kind.isToolKind is true. Each run renders as
// exactly one TurnSummaryRow; every other block (text, info) renders solo.
// No renderer may invent its own grouping — divergence is a defect.

enum TurnSummarySegment: Identifiable {
    case single(AssistantBlock)
    case thinkingTools([AssistantBlock])

    var id: String {
        switch self {
        case .single(let block):
            return "s:\(block.id.uuidString)"
        case .thinkingTools(let blocks):
            return "t:" + blocks.map { $0.id.uuidString }.joined(separator: ",")
        }
    }
}

enum TurnSummarySegments {
    /// Split blocks into render segments. Thinking/tool runs become one
    /// summary row each; text/info blocks pass through individually.
    static func segments(for blocks: [AssistantBlock]) -> [TurnSummarySegment] {
        var out: [TurnSummarySegment] = []
        var i = blocks.startIndex
        while i < blocks.endIndex {
            let kind = blocks[i].kind
            if kind == .thinking || kind.isToolKind {
                var j = blocks.index(after: i)
                while j < blocks.endIndex {
                    let k = blocks[j].kind
                    guard k == .thinking || k.isToolKind else { break }
                    j = blocks.index(after: j)
                }
                out.append(.thinkingTools(Array(blocks[i..<j])))
                i = j
            } else {
                out.append(.single(blocks[i]))
                i = blocks.index(after: i)
            }
        }
        return out
    }

    /// Deterministic fallback summary for a thinking/tool run, used when no
    /// AI-generated summary is available (e.g. history reloaded from DB, or
    /// the summary LLM call failed). Verb + key parameter per block, never
    /// bare counts. Reuses each block's existing toolDescription.
    static func fallbackSummary(for blocks: [AssistantBlock]) -> String {
        let parts = blocks.map { $0.toolDescription }.filter { !$0.isEmpty }
        if parts.isEmpty {
            // Thinking-only run.
            return AppLocalized("Thought for a while")
        }
        return parts.joined(separator: "、")
    }

    /// Text shown in the summary row: AI summary when present, a working
    /// indicator while the turn is live, deterministic fallback otherwise.
    /// The turn-end hook guarantees `turnSummary` is written at turn end (AI
    /// text on success, fallback on failure), so nil + !isWorking always has
    /// a fallback — the row never sticks on the working text.
    static func rowText(message: ChatMessage, memberBlocks: [AssistantBlock], isWorking: Bool) -> String {
        if let s = message.turnSummary, !s.isEmpty { return s }
        if isWorking { return AppLocalized("Thinking…") }
        return fallbackSummary(for: memberBlocks)
    }
}

// MARK: - Turn Summary Row
//
// 1:1 from thinking-drawer-mockup.html `.summary-row`:
// floating row (no card, no border): 21pt clock icon + gray single-line
// ellipsized text + › chevron. Exactly one per thinking/tool run.

struct TurnSummaryRow: View {
    @ObservedObject var message: ChatMessage
    /// Block IDs of this run, in order. Resolved against the live
    /// message.blocks so streaming growth is picked up.
    let memberIDs: [UUID]
    /// True while this turn is still being produced.
    var isWorking: Bool
    var onTap: () -> Void

    private var memberBlocks: [AssistantBlock] {
        memberIDs.compactMap { id in message.blocks.first(where: { $0.id == id }) }
    }

    private var text: String {
        TurnSummarySegments.rowText(message: message, memberBlocks: memberBlocks, isWorking: isWorking)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(ChatColors.secondaryText)
                    .frame(width: 21, height: 21)
                Text(text)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(14)))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(ChatColors.secondaryText)
            }
            .padding(.init(top: 8, leading: 4, bottom: 8, trailing: 4))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("turnSummaryRow")
    }
}
