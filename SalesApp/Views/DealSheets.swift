import SwiftUI

/// The frame every deal sheet shares: a title, the content, and one action.
private struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.display(19))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(.scaled(13)).foregroundStyle(Color.ink2)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.scaled(15, .medium))
                    .foregroundStyle(Color.ink2)
            }
            .padding(.bottom, 18)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
    }
}

private struct Field: View {
    let prompt: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        TextField(prompt, text: $text, axis: axis)
            .font(.scaled(15))
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
    }
}

private struct ErrorLine: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text).font(.scaled(12.5)).foregroundStyle(Color.failure).padding(.top, 10)
        }
    }
}

// MARK: - Set a next step (FR16 §4.5)

/// A line of text and four date chips — Today · Tomorrow · Mon · Pick… A date
/// picker is four taps; a chip is one.
struct NextStepSheet: View {
    let deal: Deal
    let onSaved: (Deal) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var day: CalendarDay
    @State private var picking = false
    @State private var saving = false
    @State private var error: String?

    init(deal: Deal, onSaved: @escaping (Deal) -> Void) {
        self.deal = deal
        self.onSaved = onSaved
        _text = State(initialValue: deal.nextStep ?? "")
        _day = State(initialValue: CalendarDay(deal.nextStepDate) ?? CalendarDay(Date()))
    }

    enum Choice: Hashable { case today, tomorrow, monday, pick }

    /// The four chips' days, from today in the phone's own calendar. "Mon" is
    /// the next Monday after today, so on a Monday it is a week away.
    nonisolated static func days(from today: Date = Date(), calendar: Calendar = .current) -> [Choice: CalendarDay] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let weekday = calendar.component(.weekday, from: today)        // 1 = Sunday, 2 = Monday
        let untilMonday = (2 - weekday + 7) % 7
        let monday = calendar.date(byAdding: .day, value: untilMonday == 0 ? 7 : untilMonday, to: today)!
        return [.today: CalendarDay(today, calendar: calendar),
                .tomorrow: CalendarDay(tomorrow, calendar: calendar),
                .monday: CalendarDay(monday, calendar: calendar)]
    }

    private var days: [Choice: CalendarDay] { Self.days() }

    private var mondayLabel: String {
        guard let monday = days[.monday] else { return "Mon" }
        return "Mon \(monday.day)"
    }

    private var selected: Choice {
        if picking { return .pick }
        for choice in [Choice.today, .tomorrow, .monday] where days[choice] == day { return choice }
        return .pick
    }

    var body: some View {
        SheetFrame(title: "Next step", subtitle: deal.name) {
            Field(prompt: "Chase Sam on the security questionnaire", text: $text)
                .submitLabel(.done)

            Text("WHEN")
                .font(.mono(10.5)).tracking(1).foregroundStyle(Color.ink3)
                .padding(.top, 18).padding(.bottom, 8)
            HStack(spacing: 7) {
                Chip(label: "Today", isSelected: selected == .today) { choose(.today) }
                Chip(label: "Tomorrow", isSelected: selected == .tomorrow) { choose(.tomorrow) }
                Chip(label: mondayLabel, isSelected: selected == .monday) { choose(.monday) }
                Chip(label: "Pick…", isSelected: selected == .pick) { picking = true }
            }
            if picking {
                DatePicker("Day", selection: Binding(
                    get: { day.date() },
                    set: { day = CalendarDay($0) }
                ), in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(.amber)
            }

            ErrorLine(text: error)
            Spacer(minLength: 18)
            Button(saving ? "Saving…" : "Set next step") { Task { await save() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func choose(_ choice: Choice) {
        picking = false
        if let chosen = days[choice] { day = chosen }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            onSaved(try await app.services.api.setNextStep(deal.id, step: text, date: day))
            dismiss()
        } catch let failure as APIError {
            error = failure.message
        } catch {}
    }
}

// MARK: - Confidence (FR16 §4.6)

/// Five words, tapped. The stage's default is labelled. The phone sends the
/// word and shows the override flag the server sends back (§5.4) — it never
/// works out for itself whether this is an override.
struct ConfidenceSheet: View {
    let deal: Deal
    let onSaved: (Deal) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var saving: Confidence?
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "How likely is this?",
                   subtitle: "Your judgement. No percentages — the forecast does that part.") {
            Card {
                ForEach(Array(Confidence.allCases.enumerated()), id: \.element) { index, word in
                    Button { Task { await choose(word) } } label: {
                        VStack(spacing: 0) {
                            HStack {
                                Text(word.label)
                                    .font(.scaled(15, word == deal.confidence ? .semibold : .regular))
                                    .foregroundStyle(Color.ink)
                                if word == deal.stageDefaultConfidence {
                                    Text("stage default")
                                        .font(.scaled(11.5, .medium))
                                        .foregroundStyle(Color.ink3)
                                }
                                Spacer()
                                if saving == word {
                                    ProgressView()
                                } else if word == deal.confidence {
                                    Image(systemName: "checkmark").foregroundStyle(Color.amber600)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                            if index < Confidence.allCases.count - 1 {
                                Rectangle().fill(Color.border2).frame(height: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(saving != nil)
                    .accessibilityAddTraits(word == deal.confidence ? .isSelected : [])
                    .accessibilityHint(word == deal.stageDefaultConfidence ? "Stage default" : "")
                }
            }
            Text("Set it yourself and it sticks — moving the deal to another stage won’t overwrite you.")
                .font(.scaled(12.5))
                .foregroundStyle(Color.ink2)
                .padding(.top, 12)
            ErrorLine(text: error)
        }
    }

    private func choose(_ word: Confidence) async {
        guard word != deal.confidence else { dismiss(); return }
        saving = word
        defer { saving = nil }
        do {
            onSaved(try await app.services.api.setConfidence(deal.id, to: word))
            dismiss()
        } catch let failure as APIError {
            error = failure.message
        } catch {}
    }
}

// MARK: - Log a call

struct LogCallSheet: View {
    let deal: Deal
    let people: [DealContact]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var who: DealContact?
    @State private var outcome: APIClient.CallOutcome = .connected
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "Log a call", subtitle: deal.name) {
            if !people.isEmpty {
                label("WITH")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(people) { person in
                            Chip(label: person.displayName, isSelected: who?.id == person.id) { who = person }
                        }
                    }
                }
            }
            label("HOW IT WENT")
            HStack(spacing: 7) {
                ForEach(APIClient.CallOutcome.allCases) { item in
                    Chip(label: item.label, isSelected: outcome == item) { outcome = item }
                }
            }
            label("NOTE")
            Field(prompt: "Optional", text: $note, axis: .vertical)
                .lineLimit(2...5)
            ErrorLine(text: error)
            Spacer(minLength: 18)
            Button(saving ? "Saving…" : "Log call") { Task { await save() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(saving)
        }
        .onAppear { who = who ?? people.first(where: \.isPrimary) ?? people.first }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.mono(10.5)).tracking(1).foregroundStyle(Color.ink3)
            .padding(.top, 14).padding(.bottom, 8)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await app.services.api.logCall(on: deal, with: who, outcome: outcome, note: note)
            dismiss()
        } catch let failure as APIError {
            error = failure.message
        } catch {}
    }
}

// MARK: - Email

/// Sent by the server and logged only once it has gone (FR03 §5.8), with the
/// organization's signature added on the way out.
struct EmailSheet: View {
    let deal: Deal
    let people: [DealContact]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var to: DealContact?
    @State private var subject = ""
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "Email", subtitle: deal.name) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(people) { person in
                        Chip(label: person.displayName, isSelected: to?.id == person.id) { to = person }
                    }
                }
            }
            .padding(.bottom, 12)
            Field(prompt: "Subject", text: $subject)
                .padding(.bottom, 10)
            Field(prompt: "Message", text: $message, axis: .vertical)
                .lineLimit(5...12)
            Text("Your signature is added when it sends. It goes on the timeline only once it has gone.")
                .font(.scaled(12)).foregroundStyle(Color.ink3).padding(.top, 8)
            ErrorLine(text: error)
            Spacer(minLength: 18)
            Button(sending ? "Sending…" : "Send") { Task { await send() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sending || to == nil || subject.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { to = to ?? people.first(where: \.isPrimary) ?? people.first }
    }

    private func send() async {
        guard let to else { return }
        sending = true
        defer { sending = false }
        do {
            try await app.services.api.sendEmail(on: deal, to: to, subject: subject, body: message)
            dismiss()
        } catch let failure as APIError {
            error = failure.message
        } catch {}
    }
}
