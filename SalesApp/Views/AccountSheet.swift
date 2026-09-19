import SwiftUI

/// Who is signed in, where notes go, the Face ID gate, and signing out.
struct AccountSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var error: String?
    @State private var confirmSignOut = false
    @State private var waiting = 0

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            ScreenHeader(title: "Account") {
                Button("Done") { dismiss() }
                    .font(.scaled(15, .semibold))
                    .foregroundStyle(Color.amber600)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Signed in")
                    Card {
                        ListRow(
                            icon: RowIcon(systemName: "person", tone: .neutral),
                            title: app.credentials?.userName ?? "—",
                            subtitle: app.credentials?.userEmail ?? "")
                        ListRow(
                            icon: RowIcon(systemName: "iphone", tone: .neutral),
                            title: app.credentials?.deviceName ?? "This phone",
                            subtitle: "Signed in on this phone",
                            showsDivider: false)
                    }
                    .padding(.bottom, 18)

                    if app.organizations.count > 1 {
                        SectionLabel("Notes go to")
                        OrganizationList(organizations: app.organizations, selection: $selection)
                            .onChange(of: selection) { _, id in Task { await switchTo(id) } }
                        if let error {
                            Text(error).font(.scaled(12.5)).foregroundStyle(Color.failure).padding(.top, 8)
                        }
                        Spacer().frame(height: 18)
                    }

                    SectionLabel("Privacy")
                    Card {
                        Toggle(isOn: $app.requiresUnlock) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ask for Face ID when I come back")
                                    .font(.scaled(14, .semibold))
                                    .foregroundStyle(Color.ink)
                                Text("Siri can always take a note, locked or not.")
                                    .font(.scaled(12.5))
                                    .foregroundStyle(Color.ink2)
                            }
                        }
                        .tint(.amber)
                        .padding(14)
                    }
                    .padding(.bottom, 24)

                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(14)
            }
        }
        .background(Color.appBackground)
        .onAppear { selection = app.credentials?.organizationId }
        .task { waiting = await app.services.queue.all().count }
        .confirmationDialog("Sign out of Sales on this phone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await app.signOut()
                    dismiss()
                }
            }
        } message: {
            if waiting > 0 {
                Text(waiting == 1
                     ? "One note is still waiting to send. It stays on this phone and goes up when you sign in again."
                     : "\(waiting) notes are still waiting to send. They stay on this phone and go up when you sign in again.")
            }
        }
    }

    private func switchTo(_ id: String?) async {
        guard let id, id != app.credentials?.organizationId,
              let organization = app.organizations.first(where: { $0.id == id }) else { return }
        do {
            try await app.choose(organization)
            error = nil
        } catch let failure as APIError {
            error = failure.message
            selection = app.credentials?.organizationId
        } catch {
            self.error = APIError.invalidResponse.message
            selection = app.credentials?.organizationId
        }
    }
}
