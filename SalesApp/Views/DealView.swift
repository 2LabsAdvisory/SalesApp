import SwiftUI

/// Deal (FR16 §4.4). In order of how much room each deserves: both amounts;
/// the first-year and weighted subline; stage, confidence and close; **the
/// next step, in the amber card with the only filled button on the screen**;
/// three actions; the people.
///
/// Two things change here, and only two: the next step and the confidence
/// (§5.3). Value, stage and close date are shown and not editable — they
/// happen sitting down.
struct DealView: View {
    let initial: Deal
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var screen = ScreenData<Deal>()
    @State private var people = ScreenData<[DealContact]>()
    @State private var sheet: DealSheet?
    @State private var failure: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the accessibility text sizes, side-by-side becomes one above the
    /// other, so nothing is cut or broken mid-word — least of all an amount.
    private var stacks: Bool { typeSize.isAccessibilitySize }

    enum DealSheet: Identifiable {
        case nextStep, confidence, call, email, note
        var id: Self { self }
    }

    private var deal: Deal { screen.value ?? initial }
    private var currency: String { app.credentials?.organizationCurrency ?? "CAD" }
    private var permission: WritePermission {
        WritePermission(isOnline: app.isOnline, isLive: screen.isLive)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let asOf = screen.asOf { AsOfNotice(asOf: asOf) }
                    if let failure {
                        Text(failure).font(.scaled(12.5)).foregroundStyle(Color.failure)
                    }
                    amounts
                    facts
                    nextStep
                    actions
                    peopleCard
                }
                .padding(14)
            }
            .refreshable { await load() }
        }
        .background(Color.appBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.credentials?.organizationId) { await load() }
        .sheet(item: $sheet) { which in
            switch which {
            case .nextStep:
                NextStepSheet(deal: deal) { updated in screen.replace(updated) }
            case .confidence:
                ConfidenceSheet(deal: deal) { updated in screen.replace(updated) }
            case .call:
                LogCallSheet(deal: deal, people: people.value ?? [])
            case .email:
                EmailSheet(deal: deal, people: (people.value ?? []).filter { $0.email != nil })
            case .note:
                ListeningSheet(opportunityId: deal.id)
                    .presentationDetents([.medium])
                    .presentationCornerRadius(20)
                    .presentationBackground(Color.surface)
            }
        }
    }

    private func load() async {
        let api = app.services.api
        let cache = app.services.readCache
        async let dealLoad: Void = screen.load { try await api.deal(initial.id, cache: cache) }
        async let peopleLoad: Void = people.load { try await api.dealContacts(initial.id, cache: cache) }
        _ = await (dealLoad, peopleLoad)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text(deal.name)
                    .font(.display(19))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(deal.customerName)
                    .font(.scaled(12.5))
                    .foregroundStyle(Color.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border2).frame(height: 1) }
    }

    /// Both amounts, apart and never joined by a plus; the first-year figure
    /// beneath, small, because it is the comparison and not the headline.
    private var amounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            let layout = stacks
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 18))
            layout {
                if deal.hasOneOff || !deal.hasMonthly {
                    Text(DealFormat.money(deal.oneOffCents ?? 0, currency: currency))
                        .font(.scaled(26, .bold))
                        .foregroundStyle(Color.amber600)
                }
                if deal.hasMonthly {
                    Text(DealFormat.monthly(deal.monthlyCents ?? 0, currency: currency))
                        .font(.scaled(26, .bold))
                        .foregroundStyle(Color.violet)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .monospacedDigit()
            Text("First-year \(DealFormat.money(deal.firstYearCents ?? 0, currency: currency)) · weighted \(DealFormat.money(deal.weightedFirstYearCents ?? 0, currency: currency))")
                .font(.scaled(12.5))
                .foregroundStyle(Color.ink3)
        }
    }

    private var facts: some View {
        Card {
            let layout = stacks ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                fact("Stage", deal.stageName)
                divider
                Button { sheet = .confidence } label: {
                    fact("Confidence", confidenceText, editable: permission.allowed)
                }
                .buttonStyle(.plain)
                .disabled(!permission.allowed || deal.stageKind != "open")
                .accessibilityHint(permission.reason ?? "Change how likely this is")
                divider
                fact("Close", DealFormat.closeDate(deal.expectedCloseDate))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.border2)
            .frame(width: stacks ? nil : 1, height: stacks ? 1 : nil)
    }

    private var confidenceText: String {
        guard let confidence = deal.confidence else { return "—" }
        return deal.confidenceOverridden ? "\(confidence.label) · yours" : confidence.label
    }

    private func fact(_ label: String, _ value: String, editable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.mono(10))
                .tracking(0.8)
                .foregroundStyle(Color.ink3)
            HStack(spacing: 3) {
                Text(value)
                    .font(.scaled(13.5, .semibold))
                    .foregroundStyle(Color.ink)
                if editable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentShape(Rectangle())
    }

    /// The field the whole product is built around, so on the screen with the
    /// least room it gets the most — and the only filled button.
    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEXT STEP")
                .font(.mono(10.5))
                .tracking(1)
                .foregroundStyle(Color.amber600)
            if deal.hasNextStep {
                Text(deal.nextStep ?? "")
                    .font(.scaled(17, .semibold))
                    .foregroundStyle(Color.ink)
                if let due = DealFormat.due(deal.nextStepDate) {
                    Text(due == "Today" ? "Due today" : due)
                        .font(.scaled(13, .medium))
                        .foregroundStyle(DealFormat.isLate(deal.nextStepDate) ? Color.failure : Color.ink2)
                }
                HStack(spacing: 10) {
                    Button("Change") { sheet = .nextStep }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Done") { Task { await markDone() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .disabled(!permission.allowed)
            } else {
                Text("No next step. An open deal without one is a deal drifting.")
                    .font(.scaled(14))
                    .foregroundStyle(Color.ink2)
                Button("Set the next step") { sheet = .nextStep }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!permission.allowed)
            }
            if let reason = permission.reason {
                Text(reason).font(.scaled(12)).foregroundStyle(Color.ink3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.amberTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.amber.opacity(0.5), lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionButton("Log call", systemName: "phone", sheet: .call, needsConnection: true)
            actionButton("Email", systemName: "envelope", sheet: .email, needsConnection: true)
                .disabled(!(people.value ?? []).contains { $0.email != nil })
            // A note is captured offline like any other — it has its own queue.
            actionButton("Note", systemName: "mic", sheet: .note, needsConnection: false)
        }
    }

    private func actionButton(_ label: String, systemName: String, sheet which: DealSheet, needsConnection: Bool) -> some View {
        Button { sheet = which } label: {
            VStack(spacing: 4) {
                Image(systemName: systemName).font(.system(size: 17))
                Text(label).font(.scaled(12.5, .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(Color.ink)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(needsConnection && !permission.allowed)
        .opacity(needsConnection && !permission.allowed ? 0.4 : 1)
    }

    @ViewBuilder
    private var peopleCard: some View {
        SectionLabel("Who you’re dealing with")
        let list = people.value ?? []
        if people.value == nil {
            // Not loaded is not the same as nobody: say which.
            Card { EmptyMessage(text: people.error ?? "Loading…") }
        } else if list.isEmpty {
            Card { EmptyMessage(text: "Nobody is on this deal yet.") }
        } else {
            Card {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, person in
                    ListRow(
                        icon: RowIcon(systemName: "person", tone: person.isPrimary ? .amber : .neutral),
                        title: person.displayName,
                        subtitle: [person.jobTitle, person.roleLabel].compactMap { $0 }.joined(separator: " · "),
                        showsDivider: index < list.count - 1)
                }
            }
        }
    }

    // MARK: Done

    /// The desktop's Done: clear the step, and ask for the next one straight
    /// away — setting the next as you finish the last is the habit the whole
    /// product depends on.
    private func markDone() async {
        failure = nil
        do {
            screen.replace(try await app.services.api.setNextStep(deal.id, step: nil, date: nil))
            sheet = .nextStep
        } catch let error as APIError {
            failure = error.message
        } catch {}
    }
}
