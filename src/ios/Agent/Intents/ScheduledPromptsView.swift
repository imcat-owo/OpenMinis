import SwiftUI

// MARK: - [T-scheduled-prompt 09-13] W1 settings page
//
// The honest ceiling (workorder W1's own words): iOS gives no unattended
// background execution. A scheduled prompt fires a LOCAL NOTIFICATION at the
// set time; tapping it opens the session and auto-sends the preset prompt.
// Untapped = nothing runs. The footer says exactly this — no over-promising.

struct ScheduledPromptsView: View {
    @ObservedObject private var store = ScheduledPromptStore.shared
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @State private var editing: ScheduledPrompt?
    @State private var showAdd = false

    var body: some View {
        List {
            if store.prompts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No scheduled prompts yet", systemImage: "alarm")
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text(AppLocalized("A scheduled prompt fires a local notification at the time you pick. Tapping the notification wakes the agent with your preset prompt — untapped, nothing runs (iOS does not allow apps to execute unattended in the background).",
                                          comment: "Scheduled prompts empty-state explanation"))
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
            } else {
                Section {
                    ForEach(store.prompts) { p in
                        row(p)
                    }
                    .onDelete { idx in
                        let ids = idx.map { store.prompts[$0].id }
                        Task { for id in ids { await store.remove(id: id) } }
                    }
                } footer: {
                    Text(AppLocalized("Fires a local notification at the set time. Tap it to wake the agent with your prompt. Untapped, nothing runs.",
                                      comment: "Scheduled prompts footer (honest boundary)"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalized("Scheduled Prompts"))
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalized("Add scheduled prompt"))
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                ScheduledPromptEditor(prompt: nil)
            }
        }
        .sheet(item: $editing) { p in
            NavigationStack {
                ScheduledPromptEditor(prompt: p)
            }
        }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    private func row(_ p: ScheduledPrompt) -> some View {
        let time = String(format: "%02d:%02d", p.hour, p.minute)
        return Button {
            editing = p
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title.isEmpty ? time : p.title)
                        .foregroundStyle(MinisTheme.primaryText)
                    Text("\(p.repeatRule.displayName) · \(time) · \(p.prompt)")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { p.enabled },
                    set: { v in Task { await store.setEnabled(v, id: p.id) } }
                ))
                .labelsHidden()
            }
        }
        .buttonStyle(.plain)
    }
}

struct ScheduledPromptEditor: View {
    /// nil = new.
    let prompt: ScheduledPrompt?
    @ObservedObject private var store = ScheduledPromptStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var promptText = ""
    @State private var time = Date()
    @State private var repeatRule: ScheduledPromptRepeat = .daily
    @State private var weekday: Int = 1
    @State private var enabled = true
    @State private var loaded = false

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Form {
            Section {
                TextField(AppLocalized("Title (shown on the notification)"), text: $title)
                DatePicker(AppLocalized("Time"), selection: $time, displayedComponents: .hourAndMinute)
                Picker(AppLocalized("Repeat"), selection: $repeatRule) {
                    ForEach(ScheduledPromptRepeat.allCases) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                if repeatRule == .weekly {
                    // 1 = Sunday … 7 = Saturday, matching DateComponents.
                    Picker(AppLocalized("Weekday"), selection: $weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                Toggle(AppLocalized("Enabled"), isOn: $enabled)
            } header: {
                Text(AppLocalized("Schedule"))
            }
            Section {
                TextEditor(text: $promptText)
                    .frame(minHeight: 100)
            } header: {
                Text(AppLocalized("Prompt"))
            } footer: {
                Text(AppLocalized("Sent automatically when you tap the notification. If you leave the session field empty in the manager, each fire continues the same session created by the first wake.",
                                  comment: "Scheduled prompt editor footer"))
            }
        }
        .navigationTitle(prompt == nil
            ? AppLocalized("New Scheduled Prompt")
            : AppLocalized("Edit Scheduled Prompt"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(AppLocalized("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalized("Save")) { save() }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let p = prompt {
                title = p.title
                promptText = p.prompt
                repeatRule = p.repeatRule
                weekday = p.weekday
                enabled = p.enabled
                var comps = DateComponents()
                comps.hour = p.hour
                comps.minute = p.minute
                time = Calendar.current.date(from: comps) ?? Date()
            }
        }
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        var p = prompt ?? ScheduledPrompt(title: "", prompt: "", hour: comps.hour ?? 9, minute: comps.minute ?? 0, repeatRule: .daily)
        p.title = title.trimmingCharacters(in: .whitespaces)
        p.prompt = promptText
        p.hour = comps.hour ?? 9
        p.minute = comps.minute ?? 0
        p.repeatRule = repeatRule
        p.weekday = weekday
        p.enabled = enabled
        Task {
            await store.upsert(p)
            dismiss()
        }
    }
}
