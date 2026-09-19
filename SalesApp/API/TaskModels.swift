import Foundation

/// A task (FR04), as `/api/tasks` returns it — the same shape the web app
/// reads. A nudge is a task with `source == "auto"`; its `reason` is the one
/// sentence saying why it exists.
struct TaskItem: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let reason: String?
    let notes: String?
    let dueDate: String?
    let status: String
    let priority: String
    let source: String
    let nudgeType: String?
    let opportunityId: String?
    let customerId: String?
    let contactId: String?
    let regardingName: String?
    let regardingCustomerName: String?

    var isNudge: Bool { source == "auto" }
    var isHighPriority: Bool { priority == "high" }

    /// "Meridian Health · Workflow platform", or whichever of the two exists.
    var regarding: String? {
        let parts = [regardingCustomerName, regardingName].compactMap { $0 }
        let unique = parts.enumerated().filter { index, part in !parts.prefix(index).contains(part) }.map(\.element)
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }
}

struct TaskPage: Decodable, Sendable {
    struct Counts: Decodable, Sendable, Equatable {
        let today: Int
        let overdue: Int
        let upcoming: Int
    }
    let data: [TaskItem]
    let counts: Counts
}
