import Foundation

/// How deals read on the phone. Wording follows the prototype: "1 day late",
/// "Today", "Mon", "nothing for 21 days", "Near certain — your call".
enum DealFormat {
    // MARK: Money

    /// Whole units when the amount is whole — "$12,000", not "$12,000.00".
    static func money(_ cents: Int, currency: String) -> String {
        let amount = Decimal(cents) / 100
        let whole = cents % 100 == 0
        return amount.formatted(.currency(code: currency)
            .precision(.fractionLength(whole ? 0 : 2)))
    }

    /// The recurring amount, always with its unit: "$3,000/mo".
    static func monthly(_ cents: Int, currency: String) -> String {
        "\(money(cents, currency: currency))/mo"
    }

    // MARK: Days

    /// A next step's date against today: "2 days late", "Today", "Tomorrow",
    /// "Mon", "Oct 3".
    static func due(_ raw: String?, today: CalendarDay = CalendarDay(Date()), calendar: Calendar = .current) -> String? {
        guard let day = CalendarDay(raw) else { return nil }
        let offset = day.days(from: today, calendar: calendar)
        switch offset {
        case ..<(-1): return "\(-offset) days late"
        case -1: return "1 day late"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return day.date(calendar: calendar).formatted(.dateTime.weekday(.abbreviated))
        default: return day.date(calendar: calendar).formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func isLate(_ raw: String?, today: CalendarDay = CalendarDay(Date())) -> Bool {
        guard let day = CalendarDay(raw) else { return false }
        return day < today
    }

    static func isToday(_ raw: String?, today: CalendarDay = CalendarDay(Date())) -> Bool {
        CalendarDay(raw) == today
    }

    static func closeDate(_ raw: String?) -> String {
        guard let day = CalendarDay(raw) else { return "—" }
        return day.date().formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: What a deal needs

    /// The column that earns a Pipeline row (FR16 §4.3): a step that is late
    /// or due today, else an overridden confidence, else the step and its day,
    /// else the absence of one.
    static func needs(_ deal: Deal, today: CalendarDay = CalendarDay(Date())) -> String {
        let step = deal.nextStep?.trimmingCharacters(in: .whitespaces) ?? ""
        let when = due(deal.nextStepDate, today: today)
        if !step.isEmpty, isLate(deal.nextStepDate, today: today) || isToday(deal.nextStepDate, today: today) {
            return "\(step) — \((when ?? "").lowercased())"
        }
        if deal.confidenceOverridden, let confidence = deal.confidence {
            return "\(confidence.label) — your call"
        }
        if !step.isEmpty {
            return when.map { "\(step) — \($0)" } ?? step
        }
        return "No next step"
    }

    /// Why a deal is on Today's Going quiet list.
    static func quiet(_ deal: Deal, now: Date = Date()) -> String {
        if deal.quietReason == .noNextStep { return "no next step" }
        guard let last = deal.lastActivityAt else { return "nothing logged yet" }
        let days = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
        return "nothing for \(days) days"
    }

    /// The as-of stamp on a screen read from the cache: "As of 2:14p".
    static func asOf(_ date: Date, now: Date = Date()) -> String {
        "As of \(NoteFormat.when(date, now: now))"
    }
}
