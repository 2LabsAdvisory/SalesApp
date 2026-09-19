import SwiftUI

/// Today (FR16 §4.1): the landing screen. **It leads with the overdue next
/// step, not with money** — nothing on this screen is a figure to admire.
/// Two sections, late first, then what has gone quiet; the seller's own work
/// only (FR16 §8, decision 2).
struct TodayView: View {
    @Environment(AppModel.self) private var app
    @State private var screen = ScreenData<TodayPayload>()

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
        }
        .task(id: app.credentials?.organizationId) { await load() }
    }

    private func load() async {
        await screen.load { try await app.services.api.today(cache: app.services.readCache) }
    }

    @ViewBuilder
    private var content: some View {
        if let asOf = screen.asOf {
            AsOfNotice(asOf: asOf).padding(.bottom, 14)
        }

        if let today = screen.value {
            SectionLabel("Needs you today")
            if today.due.isEmpty {
                Card { EmptyMessage(text: "Nothing late, and nothing due today.") }
            } else {
                Card {
                    ForEach(Array(today.due.enumerated()), id: \.element.id) { index, deal in
                        NavigationLink(value: deal) {
                            ListRow(
                                icon: RowIcon(systemName: "flag", tone: DealFormat.isLate(deal.nextStepDate) ? .failure : .amber),
                                title: deal.nextStep ?? deal.name,
                                subtitle: "\(deal.name) · \(deal.customerName)",
                                showsDivider: index < today.due.count - 1
                            ) {
                                Text(DealFormat.due(deal.nextStepDate) ?? "")
                                    .font(.scaled(12.5, .semibold))
                                    .foregroundStyle(DealFormat.isLate(deal.nextStepDate) ? Color.failure : Color.amber600)
                            }
                        }
                        .buttonStyle(.plain)
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
}
