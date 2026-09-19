import Foundation

/// The Pipeline's chips (FR16 §4.3). Every one is a query against the same
/// list endpoint the web app uses, so a count on the phone and a count on
/// the desktop cannot disagree.
enum PipelineFilter: String, CaseIterable, Identifiable, Sendable {
    case all, mine, closing, quiet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        case .closing: "Closing soon"
        case .quiet: "Quiet"
        }
    }

    func query(me userId: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "tab", value: "open"), URLQueryItem(name: "sort", value: "attention")]
        switch self {
        case .all: break
        case .mine: items.append(URLQueryItem(name: "owner_id", value: userId ?? ""))
        case .closing: items.append(URLQueryItem(name: "closing", value: "month"))
        case .quiet: items.append(URLQueryItem(name: "quiet", value: "true"))
        }
        return items
    }
}

enum NextStepBucket: String, CaseIterable, Identifiable, Sendable {
    case today, overdue, later
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WorkScope: String, Sendable {
    case mine, all
}

extension APIClient {
    // MARK: Reads (cached for offline, FR16 §5.6)

    func today(cache: ReadCache) async throws -> Loaded<TodayPayload> {
        let loaded = try await read(DataEnvelope<TodayPayload>.self, "today",
                                    query: [URLQueryItem(name: "scope", value: WorkScope.mine.rawValue)], cache: cache)
        return Loaded(value: loaded.value.data, asOf: loaded.asOf)
    }

    func nextSteps(_ bucket: NextStepBucket, scope: WorkScope, offset: Int = 0, cache: ReadCache) async throws -> Loaded<NextStepPage> {
        try await read(NextStepPage.self, "next-steps", query: [
            URLQueryItem(name: "due", value: bucket.rawValue),
            URLQueryItem(name: "scope", value: scope.rawValue),
            URLQueryItem(name: "offset", value: String(offset))
        ], cache: cache)
    }

    func deals(_ filter: PipelineFilter, me userId: String?, offset: Int = 0, limit: Int = 25, cache: ReadCache) async throws -> Loaded<DealPage> {
        try await read(DealPage.self, "opportunities", query: filter.query(me: userId) + [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ], cache: cache)
    }

    func deal(_ id: String, cache: ReadCache) async throws -> Loaded<Deal> {
        let loaded = try await read(DataEnvelope<Deal>.self, "opportunities/\(id)", cache: cache)
        return Loaded(value: loaded.value.data, asOf: loaded.asOf)
    }

    func dealContacts(_ id: String, cache: ReadCache) async throws -> Loaded<[DealContact]> {
        let loaded = try await read(DataEnvelope<[DealContact]>.self, "opportunities/\(id)/contacts", cache: cache)
        return Loaded(value: loaded.value.data, asOf: loaded.asOf)
    }

    // MARK: The two writes (FR16 §5.3), through the ordinary update

    /// Set, change or clear the next step. Nil clears it — sent as an
    /// explicit null, because leaving a key out means "unchanged".
    func setNextStep(_ id: String, step: String?, date: CalendarDay?) async throws -> Deal {
        let (data, _) = try await send("PUT", "opportunities/\(id)", body: Self.nextStepBody(step: step, date: date))
        return try decode(DataEnvelope<Deal>.self, from: data).data
    }

    struct NextStepBody: Encodable, Sendable {
        let nextStep: String?
        let nextStepDate: String?
        enum CodingKeys: String, CodingKey { case nextStep = "next_step", nextStepDate = "next_step_date" }
        // Both keys always present: a missing key means "unchanged" to the
        // API, and clearing a step has to say so with an explicit null.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(nextStep, forKey: .nextStep)
            try container.encode(nextStepDate, forKey: .nextStepDate)
        }
    }

    /// Blank text clears the step, and a cleared step has no date.
    static func nextStepBody(step: String?, date: CalendarDay?) -> NextStepBody {
        let text = step?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (text?.isEmpty ?? true) ? nil : text
        return NextStepBody(nextStep: clean, nextStepDate: clean == nil ? nil : date?.iso)
    }

    /// Send the word; the server decides whether it is an override and says
    /// so in what it returns (FR16 §5.4).
    func setConfidence(_ id: String, to confidence: Confidence) async throws -> Deal {
        let (data, _) = try await send("PUT", "opportunities/\(id)", body: ["confidence": confidence.rawValue])
        return try decode(DataEnvelope<Deal>.self, from: data).data
    }

    // MARK: The three actions

    enum CallOutcome: String, CaseIterable, Identifiable, Sendable {
        case connected, voicemail
        case noAnswer = "no_answer"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .connected: "Connected"
            case .voicemail: "Voicemail"
            case .noAnswer: "No answer"
            }
        }
    }

    func logCall(on deal: Deal, with contact: DealContact?, outcome: CallOutcome, note: String) async throws {
        struct Body: Encodable, Sendable {
            let activityType = "call"
            let direction = "outgoing"
            let outcome: String
            let subject: String
            let body: String?
            let opportunityId: String
            let contactId: String?
        }
        let who = contact.map { "Call with \($0.displayName)" } ?? "Call about \(deal.name)"
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await send("POST", "activities", body: Body(
            outcome: outcome.rawValue, subject: who, body: trimmed.isEmpty ? nil : trimmed,
            opportunityId: deal.id, contactId: contact?.contactId))
    }

    /// Sent first and logged only if it went (FR03 §5.8) — the server's rule.
    func sendEmail(on deal: Deal, to contact: DealContact, subject: String, body: String) async throws {
        struct Body: Encodable, Sendable {
            let to: String
            let subject: String
            let body: String
            let opportunityId: String
            let contactId: String
        }
        _ = try await send("POST", "activities/send-email", body: Body(
            to: contact.email ?? "", subject: subject, body: body,
            opportunityId: deal.id, contactId: contact.contactId))
    }
}
