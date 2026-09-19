import SwiftUI

/// Pipeline (FR16 §4.3) — **a list, not a board.** Dragging cards between
/// columns on a phone is a worse version of a good desktop idea; a list
/// sorted by what needs attention answers the question the board is for.
///
/// The header carries two figures in two units and never their sum.
struct PipelineView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: PipelineFilter = .all
    @State private var screen = ScreenData<DealPage>()
    @State private var rows: [Deal] = []
    @State private var counts: [PipelineFilter: Int] = [:]
    @State private var openTotals: DealPage.Totals?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabHeader(title: "Pipeline", subtitle: header) { EmptyView() }
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
        .task(id: "\(app.credentials?.organizationId ?? "")|\(filter)") { await load() }
    }

    private var currency: String { app.credentials?.organizationCurrency ?? "CAD" }

    /// "$111,650 · +$9,600/mo open" — two figures, two units, never added.
    private var header: String? {
        guard let totals = openTotals else { return nil }
        let oneOff = DealFormat.money(totals.oneOffCents, currency: currency)
        guard totals.monthlyCents > 0 else { return "\(oneOff) open" }
        return "\(oneOff) · +\(DealFormat.monthly(totals.monthlyCents, currency: currency)) open"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(PipelineFilter.allCases) { item in
                    Chip(label: item.label, count: counts[item], isSelected: filter == item) { filter = item }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let asOf = screen.asOf {
            AsOfNotice(asOf: asOf).padding(.bottom, 14)
        }

        if let page = screen.value {
            if rows.isEmpty {
                Card { EmptyMessage(text: "No open deals here.") }
            } else {
                Card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, deal in
                        NavigationLink(value: deal) {
                            DealRow(deal: deal, currency: currency, showsDivider: index < rows.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Showing \(rows.count) of \(page.total)")
                    .font(.scaled(12.5))
                    .foregroundStyle(Color.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                if rows.count < page.total {
                    Button("Show 25 more") { Task { await loadMore() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 8)
                }
            }
        } else if let error = screen.error {
            EmptyMessage(text: error)
        }
    }

    // MARK: Loading

    private func load() async {
        let api = app.services.api
        let cache = app.services.readCache
        let me = app.credentials?.userId
        await screen.load { try await api.deals(filter, me: me, cache: cache) }
        rows = screen.value?.data ?? []

        // Every chip's count, and the open totals, from the same endpoint —
        // one row each, since only the total matters.
        await withTaskGroup(of: (PipelineFilter, DealPage?).self) { group in
            for item in PipelineFilter.allCases {
                group.addTask { (item, try? await api.deals(item, me: me, limit: 1, cache: cache).value) }
            }
            for await (item, page) in group {
                guard let page else { continue }
                counts[item] = page.total
                if item == .all { openTotals = page.totals }
            }
        }
    }

    private func loadMore() async {
        guard let loaded = try? await app.services.api.deals(
            filter, me: app.credentials?.userId, offset: rows.count, cache: app.services.readCache) else { return }
        let known = Set(rows.map(\.id))
        rows += loaded.value.data.filter { !known.contains($0.id) }
    }
}

/// A Pipeline row: the deal, both amounts, the stage, and what it needs.
struct DealRow: View {
    let deal: Deal
    let currency: String
    let showsDivider: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deal.name)
                            .font(.scaled(14, .semibold))
                            .foregroundStyle(Color.ink)
                        Text(deal.customerName)
                            .font(.scaled(12.5))
                            .foregroundStyle(Color.ink2)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    AmountsColumn(deal: deal, currency: currency, size: 13.5,
                                  alignment: typeSize.isAccessibilitySize ? .leading : .trailing)
                }
                let tags = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 8))
                tags {
                    Text(deal.stageName)
                        .font(.scaled(11.5, .semibold))
                        .foregroundStyle(Color.ink2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.appBackground, in: Capsule())
                    Text(DealFormat.needs(deal))
                        .font(.scaled(12.5))
                        .foregroundStyle(needsColor)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            if showsDivider { Rectangle().fill(Color.border2).frame(height: 1) }
        }
    }

    private var needsColor: Color {
        if DealFormat.isLate(deal.nextStepDate) || !deal.hasNextStep { return .failure }
        if DealFormat.isToday(deal.nextStepDate) { return .amber600 }
        return .ink2
    }
}

/// One-off in amber, recurring in violet, one above the other — never side by
/// side with a plus between them (FR16 §5.5).
struct AmountsColumn: View {
    let deal: Deal
    let currency: String
    var size: CGFloat = 13.5
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            if deal.hasOneOff || !deal.hasMonthly {
                Text(DealFormat.money(deal.oneOffCents ?? 0, currency: currency))
                    .font(.scaled(size, .semibold))
                    .foregroundStyle(Color.amber600)
            }
            if deal.hasMonthly {
                Text(DealFormat.monthly(deal.monthlyCents ?? 0, currency: currency))
                    .font(.scaled(size - 1, .semibold))
                    .foregroundStyle(Color.violet)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .monospacedDigit()
    }
}
