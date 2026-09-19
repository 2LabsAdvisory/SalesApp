import Foundation
import Testing
@testable import SalesApp

/// FR16: how deals read, what the phone sends, and what it keeps.
@Suite struct DealTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Edmonton")!
        return calendar
    }()

    private func day(_ raw: String) -> CalendarDay { CalendarDay(raw)! }

    // MARK: Days

    @Test func lateness_reads_as_the_prototype_writes_it() {
        let today = day("2026-09-18")
        #expect(DealFormat.due("2026-09-17", today: today, calendar: calendar) == "1 day late")
        #expect(DealFormat.due("2026-09-15", today: today, calendar: calendar) == "3 days late")
        #expect(DealFormat.due("2026-09-18", today: today, calendar: calendar) == "Today")
        #expect(DealFormat.due("2026-09-19", today: today, calendar: calendar) == "Tomorrow")
        #expect(DealFormat.due(nil, today: today, calendar: calendar) == nil)
    }

    @Test func the_monday_chip_is_the_next_monday_and_follows_the_day_of_the_week() {
        // Thursday 18 September 2026 → Monday 21st.
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))!
        #expect(NextStepSheet.days(from: thursday, calendar: calendar)[.monday] == day("2026-09-21"))
        #expect(NextStepSheet.days(from: thursday, calendar: calendar)[.tomorrow] == day("2026-09-19"))

        // On a Monday, "Mon" is a week away, not today.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 10))!
        #expect(NextStepSheet.days(from: monday, calendar: calendar)[.monday] == day("2026-09-28"))

        // On a Sunday it is tomorrow.
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 10))!
        #expect(NextStepSheet.days(from: sunday, calendar: calendar)[.monday] == day("2026-09-21"))
    }

    @Test func a_calendar_day_is_a_day_not_an_instant() {
        #expect(day("2026-09-18").iso == "2026-09-18")
        #expect(day("2026-09-18") < day("2026-09-19"))
        #expect(CalendarDay("2026-09-18T00:00:00.000Z") == day("2026-09-18"))
        #expect(CalendarDay("not a date") == nil)
    }

    // MARK: What a deal needs

    private func deal(step: String? = nil, date: String? = nil, confidence: Confidence = .likely,
                      overridden: Bool = false, quiet: Deal.QuietReason? = nil) -> Deal {
        var json: [String: Any] = [
            "id": "d1", "organization_id": "o1", "name": "Workflow platform — 60 seats",
            "customer_name": "Meridian Health Group", "one_off_cents": 1_200_000, "recurring_cents": 300_000,
            "monthly_cents": 300_000, "first_year_cents": 4_800_000, "weighted_first_year_cents": 3_600_000,
            "stage_name": "Negotiation", "stage_kind": "open", "stage_default_confidence": "likely",
            "confidence": confidence.rawValue, "confidence_overridden": overridden
        ]
        json["next_step"] = step
        json["next_step_date"] = date
        json["quiet_reason"] = quiet?.rawValue
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder.api.decode(Deal.self, from: data)
    }

    @Test func a_row_says_what_the_deal_needs_in_the_right_order() {
        let today = day("2026-09-18")
        #expect(DealFormat.needs(deal(step: "Legal redlines back to Priya", date: "2026-09-18"), today: today)
                == "Legal redlines back to Priya — today")
        #expect(DealFormat.needs(deal(step: "Send revised scope", date: "2026-09-17"), today: today)
                == "Send revised scope — 1 day late")
        // A future step gives way to an overridden confidence, which is marked.
        #expect(DealFormat.needs(deal(step: "Renewal call", date: "2026-09-22", confidence: .nearCertain, overridden: true), today: today)
                == "Near certain — your call")
        #expect(DealFormat.needs(deal(), today: today) == "No next step")
    }

    @Test func going_quiet_says_which_of_the_two_it_is() {
        #expect(DealFormat.quiet(deal(quiet: .noNextStep)) == "no next step")
    }

    // MARK: Money and percentages

    @Test func the_seed_deal_reads_as_the_spec_says() {
        let d = deal()
        #expect(DealFormat.money(d.oneOffCents!, currency: "CAD").hasSuffix("12,000"))
        #expect(DealFormat.monthly(d.monthlyCents!, currency: "CAD").hasSuffix("3,000/mo"))
        #expect(DealFormat.money(d.firstYearCents!, currency: "CAD").hasSuffix("48,000"))
        #expect(DealFormat.money(d.weightedFirstYearCents!, currency: "CAD").hasSuffix("36,000"))
        #expect(!DealFormat.money(1_200_050, currency: "CAD").hasSuffix("12,000"), "cents were dropped")
    }

    @Test func no_percentage_appears_for_confidence_or_the_forecast() {
        // FR16 §5.2: the five words are the interface.
        for word in Confidence.allCases {
            #expect(!word.label.contains("%"))
            #expect(!DealFormat.needs(deal(step: "x", date: "2026-10-30", confidence: word, overridden: true)).contains("%"))
        }
        #expect(Confidence.allCases.map(\.label) == ["Long shot", "Unlikely", "Even odds", "Likely", "Near certain"])
    }

    // MARK: What the phone sends

    @Test func clearing_a_next_step_sends_explicit_nulls() throws {
        let body = try JSONEncoder.api.encode(APIClient.nextStepBody(step: nil, date: day("2026-09-18")))
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object.keys.sorted() == ["next_step", "next_step_date"], "a key was left out, which means unchanged")
        #expect(object["next_step"] is NSNull)
        #expect(object["next_step_date"] is NSNull, "a cleared step kept a date")

        let blank = try JSONEncoder.api.encode(APIClient.nextStepBody(step: "   ", date: day("2026-09-18")))
        let blankObject = try #require(try JSONSerialization.jsonObject(with: blank) as? [String: Any])
        #expect(blankObject["next_step"] is NSNull)

        let set = try JSONEncoder.api.encode(APIClient.nextStepBody(step: " Call Doug ", date: day("2026-09-21")))
        let setObject = try #require(try JSONSerialization.jsonObject(with: set) as? [String: Any])
        #expect(setObject["next_step"] as? String == "Call Doug")
        #expect(setObject["next_step_date"] as? String == "2026-09-21")
    }

    @Test func no_filter_sends_an_organization_id() {
        // FR16 §7: the session's active org is the only source.
        for filter in PipelineFilter.allCases {
            let names = filter.query(me: "u1").map(\.name)
            #expect(!names.contains { $0.contains("organization") })
        }
        #expect(PipelineFilter.mine.query(me: "u1").contains(URLQueryItem(name: "owner_id", value: "u1")))
    }

    // MARK: The photograph

    @Test func the_read_cache_is_per_organization_and_forgotten_on_sign_out() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ReadCacheTests-\(UUID().uuidString)")
        let cache = ReadCache(directory: directory)
        await cache.save(Data("kestrel".utf8), org: "kestrel", key: "https://x/api/today")

        #expect(await cache.load(org: "kestrel", key: "https://x/api/today")?.data == Data("kestrel".utf8))
        // Another org's session never reads this org's photograph.
        #expect(await cache.load(org: "alder", key: "https://x/api/today") == nil)

        await cache.clear()
        #expect(await cache.load(org: "kestrel", key: "https://x/api/today") == nil)
    }
}
