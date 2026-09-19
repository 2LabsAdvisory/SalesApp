import SwiftUI

/// Today (FR16 §4.1): the landing screen. **It leads with what is late, not
/// with money** — nothing on this screen is a figure to admire. Two sections,
/// late first, then what has gone quiet; the seller's own work only (FR16 §8,
/// decision 2).
///
/// "Needs you today" is next steps and tasks together (FR04), late first. The
/// nudges that describe a deal already on this screen — its overdue step, or
/// the silence "Going quiet" lists — are left out, so no deal appears twice.
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @State private var screen = ScreenData<TodayPayload>()
    @State private var overdueTasks = ScreenData<TaskPage>()
    @State private var todayTasks = ScreenData<TaskPage>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabHeader(title: "Today", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    AccountButton()
                }
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
        .task(id: app.credentials?.organizationId) { await load() }
    }

    private func load() async {
        let api = app.services.api
        let cache = app.services.readCache
        let skip = APIClient.shownOnToday
        async let today: Void = screen.load { try await api.today(cache: cache) }
        async let late: Void = overdueTasks.load { try await api.tasks(.overdue, scope: .mine, excluding: skip, cache: cache) }
        async let due: Void = todayTasks.load { try await api.tasks(.today, scope: .mine, excluding: skip, cache: cache) }
        _ = await (today, late, due)
    }

    /// Late first, then today: the order the section promises.
    private func needsYou(_ today: TodayPayload) -> [WorkItem] {
        let tasks = (overdueTasks.value?.data ?? []) + (todayTasks.value?.data ?? [])
        return WorkItem.merged(tasks: tasks, steps: today.due)
    }

    @ViewBuilder
    private var content: some View {
        if let asOf = screen.asOf {
            AsOfNotice(asOf: asOf).padding(.bottom, 14)
        }

        if let today = screen.value {
            SectionLabel("Needs you today")
            let items = needsYou(today)
            if items.isEmpty {
                Card { EmptyMessage(text: "Nothing late, and nothing due today.") }
            } else {
                Card {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        needsYouRow(item, isLast: index == items.count - 1)
                    }
                }
            }

            Spacer().frame(height: 18)
            SectionLabel("Going quiet")
            if today.quiet.isEmpty {
                Card { EmptyMessage(text: "Every open deal has a next step and something recent.") }
            } else {
                Card {
                    ForEach(Array(today.quiet.enumerated()), id: \.element.id) { index, deal in
                        NavigationLink(value: deal) {
                            ListRow(
                                icon: RowIcon(systemName: deal.quietReason == .noNextStep ? "questionmark" : "moon", tone: .neutral),
                                title: deal.name,
                                subtitle: "\(deal.customerName) · \(DealFormat.quiet(deal))",
                                showsDivider: index < today.quiet.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if let error = screen.error {
            EmptyMessage(text: error)
        }

        SiriPrompt()
    }

    @ViewBuilder
    private func needsYouRow(_ item: WorkItem, isLast: Bool) -> some View {
        let late = DealFormat.isLate(item.dueDate)
        let due = Text(DealFormat.due(item.dueDate) ?? "")
            .font(.scaled(12.5, .semibold))
            .foregroundStyle(late ? Color.failure : Color.amber600)
        switch item {
        case .step(let deal):
            NavigationLink(value: deal) {
                ListRow(
                    icon: RowIcon(systemName: "flag", tone: late ? .failure : .amber),
                    title: deal.nextStep ?? deal.name,
                    subtitle: "\(deal.name) · \(deal.customerName)",
                    showsDivider: !isLast
                ) { due }
            }
            .buttonStyle(.plain)
        case .task(let task):
            let row = ListRow(
                icon: RowIcon(systemName: task.isNudge ? "bell" : "checklist", tone: late ? .failure : .amber),
                title: task.title,
                subtitle: [task.isNudge ? "Nudge" : nil, task.regarding ?? task.notes].compactMap { $0 }.joined(separator: " · "),
                showsDivider: !isLast
            ) { due }
            if let dealId = task.opportunityId {
                NavigationLink(value: DealLink(id: dealId)) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
    }
}
