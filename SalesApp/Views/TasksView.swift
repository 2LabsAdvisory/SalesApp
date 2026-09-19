import SwiftUI

/// One row on the Tasks tab: a task (FR04), or a deal's next step. Since FR04
/// a next step is one kind of task among others (FR16 §8, decision 4) — it
/// stays a row of its own because its Done is different: it clears the step
/// on the deal, which also resolves any "next step overdue" nudge about it.
enum WorkItem: Identifiable, Hashable, Sendable {
    case task(TaskItem)
    case step(Deal)

    var id: String {
        switch self {
        case .task(let task): "task-\(task.id)"
        case .step(let deal): "step-\(deal.id)"
        }
    }

    var dueDate: String? {
        switch self {
        case .task(let task): task.dueDate
        case .step(let deal): deal.nextStepDate
        }
    }

    /// Soonest first, undated last; ties keep the server's order.
    static func merged(tasks: [TaskItem], steps: [Deal]) -> [WorkItem] {
        let items = tasks.map(WorkItem.task) + steps.map(WorkItem.step)
        return items.enumerated().sorted { a, b in
            switch (CalendarDay(a.element.dueDate), CalendarDay(b.element.dueDate)) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// Where a task row goes when tapped: its deal, loaded by id.
struct DealLink: Hashable {
    let id: String
}

/// Tasks (FR16 §4.2) — tasks and nudges from FR04, and each deal's next step.
///
/// Today · Overdue · Later, with live counts, and Mine / All. Ticking a row is
/// one tap with no confirmation: a task is marked done — the same completion
/// the desktop uses — and a next step is cleared, as the desktop's Done does.
/// The row then says *Done · Undo* for a few seconds before it leaves (§8,
/// decision 3), and Undo puts it back exactly as it was.
struct TasksView: View {
    @Environment(AppModel.self) private var app
    @State private var bucket: NextStepBucket = .today
    @State private var scope: WorkScope = .mine
    @State private var steps = ScreenData<NextStepPage>()
    @State private var taskPage = ScreenData<TaskPage>()
    @State private var stepRows: [Deal] = []
    @State private var taskRows: [TaskItem] = []
    @State private var done: [String: WorkItem] = [:]      // ticked, still offering Undo
    @State private var failure: String?

    private static let undoWindow: Duration = .seconds(5)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabHeader(title: "Tasks", subtitle: summary) {
                    Chip(label: scope == .mine ? "Mine" : "All", isSelected: false) {
                        scope = scope == .mine ? .all : .mine
                    }
                }
                chips
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }
                .refreshable { await load() }
            }
            .background(Color.appBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Deal.self) { DealView(initial: $0) }
            .navigationDestination(for: DealLink.self) { DealLoaderView(id: $0.id) }
        }
        .task(id: "\(app.credentials?.organizationId ?? "")|\(bucket)|\(scope)") { await load() }
    }

    private var rows: [WorkItem] { WorkItem.merged(tasks: taskRows, steps: stepRows) }

    /// Tasks and steps together. Either count alone would be a wrong number.
    private func count(of item: NextStepBucket) -> Int? {
        guard let s = steps.value?.counts, let t = taskPage.value?.counts else { return nil }
        switch item {
        case .today: return s.today + t.today
        case .overdue: return s.overdue + t.overdue
        case .later: return s.later + t.upcoming
        }
    }

    private var summary: String? {
        guard let overdue = count(of: .overdue), let today = count(of: .today) else { return nil }
        return "\(overdue) overdue · \(today) today"
    }

    private var chips: some View {
        HStack(spacing: 7) {
            ForEach(NextStepBucket.allCases) { item in
                Chip(label: item.label, count: count(of: item), isSelected: bucket == item) { bucket = item }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    /// Showing the last successful load is fine; writing from it is not.
    private var asOf: Date? { steps.asOf ?? taskPage.asOf }

    private var permission: WritePermission {
        WritePermission(isOnline: app.isOnline, isLive: asOf == nil)
    }

    @ViewBuilder
    private var content: some View {
        if let asOf {
            AsOfNotice(asOf: asOf).padding(.bottom, 14)
        }
        if let failure {
            Text(failure).font(.scaled(12.5)).foregroundStyle(Color.failure).padding(.bottom, 10)
        }

        if steps.value != nil, taskPage.value != nil {
            let rows = rows
            if rows.isEmpty {
                Card { EmptyMessage(text: emptyText) }
            } else {
                Card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        row(item, isLast: index == rows.count - 1)
                    }
                }
                if let page = steps.value, stepRows.count < page.total {
                    Button("Show more next steps") { Task { await loadMoreSteps() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 12)
                }
            }
        } else if let error = steps.error ?? taskPage.error {
            EmptyMessage(text: error)
        }
    }

    private var emptyText: String {
        switch bucket {
        case .today: "Nothing due today."
        case .overdue: "Nothing overdue."
        case .later: "Nothing planned further out."
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: WorkItem, isLast: Bool) -> some View {
        let isDone = done[item.id] != nil
        HStack(spacing: 0) {
            Button {
                Task { await tick(item) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isDone ? Color.success : Color.ink3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isDone || !permission.allowed)
            .accessibilityLabel(isDone ? "Done" : "Mark done")
            .accessibilityHint(permission.reason ?? "")

            switch item {
            case .step(let deal):
                NavigationLink(value: deal) {
                    ListRow(
                        icon: RowIcon(systemName: "flag", tone: DealFormat.isLate(deal.nextStepDate) ? .failure : .amber),
                        title: deal.nextStep ?? deal.name,
                        subtitle: isDone ? "Done" : "Next step · \(deal.name) · \(deal.customerName)",
                        showsDivider: !isLast
                    ) { trailing(item, isDone: isDone) }
                }
                .buttonStyle(.plain)
            case .task(let task):
                let label = ListRow(
                    icon: RowIcon(systemName: task.isNudge ? "bell" : "checklist",
                                  tone: DealFormat.isLate(task.dueDate) ? .failure : .amber),
                    title: task.title,
                    subtitle: isDone ? "Done" : subtitle(for: task),
                    showsDivider: !isLast
                ) { trailing(item, isDone: isDone) }
                if let dealId = task.opportunityId {
                    NavigationLink(value: DealLink(id: dealId)) { label }.buttonStyle(.plain)
                } else {
                    label
                }
            }
        }
        .padding(.leading, 4)
    }

    /// A nudge says it is one, and why it exists — a task you cannot explain
    /// is the first thing you delete (FR04 §7.1).
    private func subtitle(for task: TaskItem) -> String {
        let parts: [String?] = task.isNudge
            ? ["Nudge", task.reason ?? task.regarding]
            : [task.isHighPriority ? "High" : nil, task.regarding ?? task.notes]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func trailing(_ item: WorkItem, isDone: Bool) -> some View {
        if isDone {
            Button("Undo") { Task { await undo(item) } }
                .font(.scaled(13, .semibold))
                .foregroundStyle(Color.amber600)
        } else if let due = DealFormat.due(item.dueDate) {
            Text(due)
                .font(.scaled(12.5, .semibold))
                .foregroundStyle(DealFormat.isLate(item.dueDate) ? Color.failure : Color.ink2)
        }
    }

    // MARK: Loading

    private func load() async {
        done = [:]
        let api = app.services.api
        let cache = app.services.readCache
        async let stepLoad: Void = steps.load { try await api.nextSteps(bucket, scope: scope, cache: cache) }
        async let taskLoad: Void = taskPage.load { try await api.tasks(bucket, scope: scope, cache: cache) }
        _ = await (stepLoad, taskLoad)
        stepRows = steps.value?.data ?? []
        taskRows = taskPage.value?.data ?? []
    }

    private func loadMoreSteps() async {
        guard let loaded = try? await app.services.api.nextSteps(
            bucket, scope: scope, offset: stepRows.count, cache: app.services.readCache) else { return }
        let known = Set(stepRows.map(\.id))
        stepRows += loaded.value.data.filter { !known.contains($0.id) }
    }

    // MARK: Done and Undo

    private func tick(_ item: WorkItem) async {
        failure = nil
        done[item.id] = item
        do {
            switch item {
            case .task(let task): try await app.services.api.completeTask(task.id)
            case .step(let deal): _ = try await app.services.api.setNextStep(deal.id, step: nil, date: nil)
            }
        } catch {
            done[item.id] = nil
            if let error = error as? APIError { failure = error.message }
            return
        }
        try? await Task.sleep(for: Self.undoWindow)
        guard done[item.id] != nil else { return }        // undone meanwhile
        done[item.id] = nil
        remove(item)
        await refreshCounts()
    }

    /// Put it back exactly as it was: the task reopened, or the step's same
    /// words and the same day.
    private func undo(_ item: WorkItem) async {
        guard let original = done[item.id] else { return }
        done[item.id] = nil
        do {
            switch original {
            case .task(let task): try await app.services.api.reopenTask(task.id)
            case .step(let deal):
                _ = try await app.services.api.setNextStep(
                    deal.id, step: deal.nextStep, date: CalendarDay(deal.nextStepDate))
            }
        } catch let error as APIError {
            failure = "Couldn’t undo: \(error.message)"
            remove(item)
        } catch {}
    }

    private func remove(_ item: WorkItem) {
        switch item {
        case .task(let task): taskRows.removeAll { $0.id == task.id }
        case .step(let deal): stepRows.removeAll { $0.id == deal.id }
        }
    }

    private func refreshCounts() async {
        let api = app.services.api
        let cache = app.services.readCache
        if let loaded = try? await api.nextSteps(bucket, scope: scope, cache: cache) { steps.replace(loaded.value) }
        if let loaded = try? await api.tasks(bucket, scope: scope, cache: cache) { taskPage.replace(loaded.value) }
    }
}

/// A deal opened from a task, which carries only the deal's id.
struct DealLoaderView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var screen = ScreenData<Deal>()

    var body: some View {
        Group {
            if let deal = screen.value {
                DealView(initial: deal)
            } else if let error = screen.error {
                EmptyMessage(text: error).padding()
            } else {
                ProgressView()
            }
        }
        .task { await screen.load { try await app.services.api.deal(id, cache: app.services.readCache) } }
    }
}
