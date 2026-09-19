import SwiftUI

/// Tasks (FR16 §4.2) — until FR04, the list of next steps (§8, decision 4).
///
/// Today · Overdue · Later, with live counts, and Mine / All. Ticking a row
/// does what the desktop's Done does — it clears the step — in one tap with
/// no confirmation. The row then says *Done · Undo* for a few seconds before
/// it leaves (§8, decision 3); Undo puts the step back exactly as it was.
struct TasksView: View {
    @Environment(AppModel.self) private var app
    @State private var bucket: NextStepBucket = .today
    @State private var scope: WorkScope = .mine
    @State private var screen = ScreenData<NextStepPage>()
    @State private var rows: [Deal] = []
    @State private var done: [String: Deal] = [:]      // ticked, still offering Undo
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
        }
        .task(id: "\(app.credentials?.organizationId ?? "")|\(bucket)|\(scope)") { await load() }
    }

    private var counts: NextStepPage.Counts? { screen.value?.counts }

    private var summary: String? {
        guard let counts else { return nil }
        return "\(counts.overdue) overdue · \(counts.today) today"
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

    private func count(of item: NextStepBucket) -> Int? {
        guard let counts else { return nil }
        switch item {
        case .today: return counts.today
        case .overdue: return counts.overdue
        case .later: return counts.later
        }
    }

    private var permission: WritePermission {
        WritePermission(isOnline: app.isOnline, isLive: screen.asOf == nil)
    }

    @ViewBuilder
    private var content: some View {
        if let asOf = screen.asOf {
            AsOfNotice(asOf: asOf).padding(.bottom, 14)
        }
        if let failure {
            Text(failure).font(.scaled(12.5)).foregroundStyle(Color.failure).padding(.bottom, 10)
        }

        if screen.value != nil {
            if rows.isEmpty {
                Card { EmptyMessage(text: emptyText) }
            } else {
                Card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, deal in
                        row(deal, isLast: index == rows.count - 1)
                    }
                }
                if let page = screen.value, rows.count < page.total {
                    Button("Show 25 more") { Task { await loadMore() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 12)
                }
            }
        } else if let error = screen.error {
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

    private func row(_ deal: Deal, isLast: Bool) -> some View {
        let isDone = done[deal.id] != nil
        return HStack(spacing: 0) {
            Button {
                Task { await tick(deal) }
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

            NavigationLink(value: deal) {
                ListRow(
                    icon: RowIcon(systemName: "flag", tone: DealFormat.isLate(deal.nextStepDate) ? .failure : .amber),
                    title: deal.nextStep ?? deal.name,
                    subtitle: isDone ? "Done" : "\(deal.name) · \(deal.customerName)",
                    showsDivider: !isLast
                ) {
                    if isDone {
                        Button("Undo") { Task { await undo(deal) } }
                            .font(.scaled(13, .semibold))
                            .foregroundStyle(Color.amber600)
                    } else if let due = DealFormat.due(deal.nextStepDate) {
                        Text(due)
                            .font(.scaled(12.5, .semibold))
                            .foregroundStyle(DealFormat.isLate(deal.nextStepDate) ? Color.failure : Color.ink2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
    }

    // MARK: Loading

    private func load() async {
        done = [:]
        await screen.load {
            try await app.services.api.nextSteps(bucket, scope: scope, cache: app.services.readCache)
        }
        rows = screen.value?.data ?? []
    }

    private func loadMore() async {
        guard let loaded = try? await app.services.api.nextSteps(
            bucket, scope: scope, offset: rows.count, cache: app.services.readCache) else { return }
        let known = Set(rows.map(\.id))
        rows += loaded.value.data.filter { !known.contains($0.id) }
    }

    // MARK: Done and Undo

    /// Clear the step — the desktop's Done — and hold the row for Undo.
    private func tick(_ deal: Deal) async {
        failure = nil
        done[deal.id] = deal
        do {
            _ = try await app.services.api.setNextStep(deal.id, step: nil, date: nil)
        } catch let error as APIError {
            done[deal.id] = nil
            failure = error.message
            return
        } catch {
            done[deal.id] = nil
            return
        }
        try? await Task.sleep(for: Self.undoWindow)
        guard done[deal.id] != nil else { return }        // undone meanwhile
        done[deal.id] = nil
        rows.removeAll { $0.id == deal.id }
        await refreshCounts()
    }

    /// Put the step back exactly as it was: the same words and the same day.
    private func undo(_ deal: Deal) async {
        guard let original = done[deal.id] else { return }
        done[deal.id] = nil
        do {
            _ = try await app.services.api.setNextStep(
                original.id, step: original.nextStep, date: CalendarDay(original.nextStepDate))
        } catch let error as APIError {
            failure = "Couldn’t undo: \(error.message)"
            rows.removeAll { $0.id == deal.id }
        } catch {}
    }

    private func refreshCounts() async {
        if let loaded = try? await app.services.api.nextSteps(bucket, scope: scope, cache: app.services.readCache) {
            screen.replace(loaded.value)
        }
    }
}
