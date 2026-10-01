import SwiftUI

// MARK: - [s2-askuser] 问用户弹窗
//
// 与 ToolApprovalDialog 同风格的 sheet：标题＋问题卡（单选/多选按钮＋"其他"自填＋
// 跳过）＋提交/全部跳过。消费底座 tag == "ask-user"（实时问询）和
// "ask-user-restored"（App 被杀后没答完的问题）的挂起。

struct AskUserDialogModifier: ViewModifier {
    @ObservedObject private var suspension = ToolSuspensionService.shared
    @ObservedObject var vm: AIChatViewModel

    func body(content: Content) -> some View {
        content.sheet(item: askRequest) { request in
            AskUserDialogContent(request: request, vm: vm)
                .id(request.id) // 换一条问询时重置作答状态（@State 不随 item 更新）
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
    }

    private var askRequest: Binding<SuspendedRequest?> {
        Binding(
            get: { suspension.askRequestForSession(vm.sessionId) },
            set: { _ in }
        )
    }
}

/// 单题的作答状态。
private struct QuestionAnswerState {
    var selected: Set<Int> = []
    var otherSelected = false
    var otherText = ""
    var skipped = false
}

private struct AskUserDialogContent: View {
    let request: SuspendedRequest
    @ObservedObject var vm: AIChatViewModel
    @State private var states: [QuestionAnswerState] = []

    private var payload: AskPayload? {
        if case .askUser(let p) = request.kind { return p }
        return nil
    }

    private var isRestored: Bool { request.tag == "ask-user-restored" }

    /// 会话历史没加载完之前不让提交——恢复的答案要配对进原历史，
    /// 空历史投进去会变成配不上的孤儿 tool_result。
    private var isSessionReady: Bool { !vm.isLoadingSession }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(ChatColors.accent)

                        Text(payload?.title ?? "AI 想问你几个问题")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)

                        if isRestored {
                            Text("这是之前没答完的问题，答完 AI 会从断点继续。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Question cards
                    if let payload {
                        ForEach(payload.questions.indices, id: \.self) { idx in
                            let q = payload.questions[idx]
                            questionCard(question: q, index: idx)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }

            // Buttons — pinned to the bottom, always tappable.
            VStack(spacing: 10) {
                if !isSessionReady {
                    Text("会话加载中，稍候即可作答…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    submit()
                } label: {
                    Text("提交回答")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(ChatColors.accent)
                .disabled(!isSessionReady)

                Button {
                    ToolSuspensionService.shared.respond(id: request.id, decision: .skipped)
                } label: {
                    Text("全部跳过")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(!isSessionReady)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            if let payload, states.count != payload.questions.count {
                states = Array(repeating: QuestionAnswerState(), count: payload.questions.count)
            }
        }
    }

    private func questionCard(question: AskQuestion, index: Int) -> some View {
        let isMulti = question.type == "multi"
        return VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.subheadline.bold())

            if index < states.count && !states[index].skipped {
                // Options
                ForEach(Array(question.options.enumerated()), id: \.offset) { optIdx, option in
                    optionRow(
                        label: option,
                        selected: index < states.count && states[index].selected.contains(optIdx),
                        icon: isMulti ? "checkmark.square" : "circle",
                        selectedIcon: isMulti ? "checkmark.square.fill" : "circle.inset.filled"
                    ) {
                        toggleOption(questionIndex: index, optionIndex: optIdx, isMulti: isMulti)
                    }
                }

                // "其他（自填）"
                optionRow(
                    label: "其他（自填）",
                    selected: index < states.count && states[index].otherSelected,
                    icon: isMulti ? "checkmark.square" : "circle",
                    selectedIcon: isMulti ? "checkmark.square.fill" : "circle.inset.filled"
                ) {
                    toggleOther(questionIndex: index, isMulti: isMulti)
                }

                if index < states.count && states[index].otherSelected {
                    TextField("在这里输入你的答案…", text: Binding(
                        get: { states[index].otherText },
                        set: { states[index].otherText = $0 }
                    ))
                    .font(.footnote)
                    .padding(10)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // 跳过这题
                Button {
                    states[index].skipped = true
                } label: {
                    Text("跳过这题")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if index < states.count {
                HStack {
                    Text("已跳过")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新作答") {
                        states[index].skipped = false
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func optionRow(label: String, selected: Bool, icon: String, selectedIcon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? selectedIcon : icon)
                    .foregroundStyle(selected ? ChatColors.accent : .secondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleOption(questionIndex: Int, optionIndex: Int, isMulti: Bool) {
        guard questionIndex < states.count else { return }
        if isMulti {
            if states[questionIndex].selected.contains(optionIndex) {
                states[questionIndex].selected.remove(optionIndex)
            } else {
                states[questionIndex].selected.insert(optionIndex)
            }
        } else {
            states[questionIndex].selected = [optionIndex]
            states[questionIndex].otherSelected = false
        }
    }

    private func toggleOther(questionIndex: Int, isMulti: Bool) {
        guard questionIndex < states.count else { return }
        if isMulti {
            states[questionIndex].otherSelected.toggle()
        } else {
            states[questionIndex].otherSelected = true
            states[questionIndex].selected = []
        }
    }

    /// 组装答案 JSON：{题 id: 选项字符串 / 选项数组 / 自填字符串 / null(跳过)}。
    private func submit() {
        guard let payload else { return }
        var answers: [String: Any] = [:]
        for (idx, q) in payload.questions.enumerated() {
            let st = idx < states.count ? states[idx] : QuestionAnswerState()
            let isMulti = q.type == "multi"
            if st.skipped {
                answers[q.id] = NSNull()
                continue
            }
            let otherText = st.otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            if isMulti {
                var picked = st.selected.sorted().compactMap { i in
                    i < q.options.count ? q.options[i] : nil
                }
                if st.otherSelected, !otherText.isEmpty { picked.append(otherText) }
                answers[q.id] = picked.isEmpty ? NSNull() : picked
            } else {
                if st.otherSelected, !otherText.isEmpty {
                    answers[q.id] = otherText
                } else if let first = st.selected.sorted().first, first < q.options.count {
                    answers[q.id] = q.options[first]
                } else {
                    answers[q.id] = NSNull()
                }
            }
        }
        let json = (try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        ToolSuspensionService.shared.respond(id: request.id, decision: .answered(json))
    }
}

extension View {
    func askUserDialog(vm: AIChatViewModel) -> some View {
        modifier(AskUserDialogModifier(vm: vm))
    }
}
