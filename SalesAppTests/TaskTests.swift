import Foundation
import Testing
@testable import SalesApp

/// FR04 on the phone: the Tasks tab reads tasks, and a next step is one kind
/// of task among others (FR16 §8, decision 4).
@Suite struct TaskTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder.api.decode(type, from: data)
    }

    private func task(_ id: String, due: String?, source: String = "manual", reason: String? = nil) -> TaskItem {
        var json: [String: Any] = [
            "id": id, "title": "Task \(id)", "status": "open", "priority": "normal", "source": source,
            "opportunity_id": "d1", "regarding_name": "Operations rollout", "regarding_customer_name": "Coastal Freight"
        ]
        json["due_date"] = due
        json["reason"] = reason
        json["nudge_type"] = source == "auto" ? "quiet" : nil
        return decode(TaskItem.self, json)
    }

    private func step(_ id: String, due: String?) -> Deal {
        var json: [String: Any] = [
            "id": id, "organization_id": "o1", "name": "Deal \(id)", "customer_name": "Meridian",
            "stage_name": "Proposal", "stage_kind": "open", "confidence_overridden": false, "next_step": "Call"
        ]
        json["next_step_date"] = due
        return decode(Deal.self, json)
    }

    @Test func tasks_and_next_steps_share_one_list_soonest_first_undated_last() {
        let merged = WorkItem.merged(
            tasks: [task("t-late", due: "2026-09-15"), task("t-none", due: nil), task("t-today", due: "2026-09-19")],
            steps: [step("s-late", due: "2026-09-17"), step("s-none", due: nil)])
        #expect(merged.map(\.id) == ["task-t-late", "step-s-late", "task-t-today", "task-t-none", "step-s-none"])
    }

    @Test func a_task_row_and_a_step_row_never_share_an_id() {
        // A deal id and a task id could collide as strings; the rows cannot.
        let items = WorkItem.merged(tasks: [task("x", due: nil)], steps: [step("x", due: nil)])
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func a_nudge_decodes_as_one_and_names_what_it_is_about() {
        let nudge = task("n", due: "2026-09-19", source: "auto", reason: "Nothing has been logged on Operations rollout since 1 September 2026.")
        #expect(nudge.isNudge)
        #expect(nudge.regarding == "Coastal Freight · Operations rollout")
        #expect(!task("m", due: nil).isNudge)
    }

    @Test func later_on_the_phone_is_upcoming_on_the_server() {
        #expect(NextStepBucket.later.taskBucket == "upcoming")
        #expect(NextStepBucket.overdue.taskBucket == "overdue")
    }

    @Test func today_leaves_out_every_nudge_it_already_shows_as_a_deal() {
        func excluded(_ list: [String]) -> String? {
            APIClient.taskQuery(.overdue, scope: .mine, excluding: list).first { $0.name == "except_nudge" }?.value
        }
        #expect(excluded(APIClient.shownOnToday) == "stepdue,quiet,nostep")
        #expect(excluded(APIClient.shownAsSteps) == "stepdue")
        let owner = APIClient.taskQuery(.today, scope: .mine, excluding: []).first { $0.name == "owner" }?.value
        #expect(owner == "me", "Today is mine (FR16 §8, decision 2)")
    }

    @Test func the_task_list_leaves_out_the_nudge_the_step_row_already_is() {
        // Decoded from exactly what /api/tasks returns for counts.
        let page = decode(TaskPage.self, ["data": [], "counts": ["today": 1, "overdue": 2, "upcoming": 3, "completed": 4, "nudges_open": 1]])
        #expect(page.counts == TaskPage.Counts(today: 1, overdue: 2, upcoming: 3))
    }
}
