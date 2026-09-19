import Foundation

// Deals, as the phone reads them (FR16). Every field here comes from the
// endpoints the web app uses; nothing is computed on the phone that the
// server already computes — first-year and weighted figures arrive as sent.

/// The five words (FR14 §4.3). The scores behind them never leave the
/// database, and no percentage is ever shown — on screen, in an accessibility
/// label, anywhere (FR16 §5.2).
enum Confidence: String, Codable, Sendable, CaseIterable, Identifiable {
    case longShot = "long_shot"
    case unlikely
    case evenOdds = "even_odds"
    case likely
    case nearCertain = "near_certain"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .longShot: "Long shot"
        case .unlikely: "Unlikely"
        case .evenOdds: "Even odds"
        case .likely: "Likely"
        case .nearCertain: "Near certain"
        }
    }
}

struct Deal: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let organizationId: String
    let name: String
    let customerName: String
    let ownerId: String?

    // Two amounts, never added (FR14 §4.1a). The first-year figure is a
    // different thing — one-off plus twelve months — and arrives computed.
    let oneOffCents: Int?
    let recurringCents: Int?
    let recurringPeriod: String?
    let monthlyCents: Int?
    let firstYearCents: Int?
    let weightedFirstYearCents: Int?

    let stageName: String
    let stageKind: String
    let stageDefaultConfidence: Confidence?
    let confidence: Confidence?
    /// Set and cleared by the server, never inferred here (FR16 §5.4).
    let confidenceOverridden: Bool

    let nextStep: String?
    /// A calendar day, `YYYY-MM-DD`, with no time zone.
    let nextStepDate: String?
    let expectedCloseDate: String?
    let lastActivityAt: Date?

    /// Only on Today's Going quiet rows: why it is there.
    let quietReason: QuietReason?

    enum QuietReason: String, Decodable, Sendable {
        case noNextStep = "no_next_step"
        case noActivity = "no_activity"
    }

    var hasNextStep: Bool { !(nextStep ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var hasMonthly: Bool { (monthlyCents ?? 0) > 0 }
    var hasOneOff: Bool { (oneOffCents ?? 0) > 0 }
}

struct DealContact: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let contactId: String
    let isPrimary: Bool
    let displayName: String
    let jobTitle: String?
    let role: String?
    let email: String?
    let phone: String?

    /// "decision maker", not "decision_maker"; nothing for "unknown".
    var roleLabel: String? {
        guard let role, role != "unknown" else { return nil }
        return role.replacingOccurrences(of: "_", with: " ")
    }
}

struct DealPage: Decodable, Sendable {
    struct Totals: Decodable, Sendable {
        let oneOffCents: Int
        let monthlyCents: Int
    }
    let data: [Deal]
    let total: Int
    let totals: Totals
}

struct TodayPayload: Decodable, Sendable {
    let due: [Deal]
    let quiet: [Deal]
    let quietDays: Int
}

struct NextStepPage: Decodable, Sendable {
    struct Counts: Decodable, Sendable, Equatable {
        let overdue: Int
        let today: Int
        let later: Int
    }
    let data: [Deal]
    let total: Int
    let counts: Counts
}

// MARK: - Calendar days

/// A `YYYY-MM-DD` day, compared in the phone's own calendar. Dates on a deal
/// are days, not instants: "due the 22nd" is the 22nd wherever you are.
struct CalendarDay: Comparable, Hashable, Sendable {
    let year: Int, month: Int, day: Int

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        (year, month, day) = (parts[0], parts[1], parts[2])
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        (year, month, day) = (c.year!, c.month!, c.day!)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Whole days from `other` to this day: negative is in the past.
    func days(from other: CalendarDay, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: other.date(calendar: calendar), to: date(calendar: calendar)).day ?? 0
    }

    static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}
