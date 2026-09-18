import SwiftUI

/// FR12's picker, on the phone: someone in more than one organization chooses
/// where to work. It starts on the one they used last, which is also where a
/// Siri note goes (FR15 §8, decision 2).
struct OrganizationPickerView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Where are you working?")
                .font(.display(22, weight: .heavy))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Notes you take go to this organization. You can change it later from your account.")
                .font(.system(size: 14))
                .foregroundStyle(Color.ink2)
                .padding(.top, 8)
                .padding(.bottom, 22)

            OrganizationList(organizations: app.organizations, selection: $selection)

            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Color.failure).padding(.top, 12)
            }

            Button("Continue") { Task { await choose() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selection == nil || isWorking)
                .padding(.top, 18)
            Spacer()
        }
        .padding(.horizontal, 28)
        .background(Color.surface.ignoresSafeArea())
        .onAppear { selection = app.credentials?.organizationId }
    }

    private func choose() async {
        guard let organization = app.organizations.first(where: { $0.id == selection }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.choose(organization)
        } catch let failure as APIError {
            error = failure.message
        } catch {
            self.error = APIError.invalidResponse.message
        }
    }
}

struct OrganizationList: View {
    let organizations: [Organization]
    @Binding var selection: String?

    var body: some View {
        Card {
            ForEach(Array(organizations.enumerated()), id: \.element.id) { index, organization in
                Button {
                    selection = organization.id
                } label: {
                    ListRow(
                        icon: RowIcon(systemName: "building.2", tone: selection == organization.id ? .amber : .neutral),
                        title: organization.name,
                        subtitle: organization.role == "org_admin" ? "Org admin" : "User",
                        showsDivider: index < organizations.count - 1
                    ) {
                        if selection == organization.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.amber600)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == organization.id ? .isSelected : [])
            }
        }
    }
}
