import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                Color.appBackground.ignoresSafeArea()
            case .signedOut:
                SignInView()
            case .choosingOrganization:
                OrganizationPickerView()
            case .signedIn:
                MainShell()
            }

            if app.isLocked {
                // Covers instantly — no fade-in for the notes to show through,
                // including in the app switcher's snapshot — and fades away
                // only once unlocked.
                LockView()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.isLocked)
        .preferredColorScheme(.light)
        .tint(.amber)
    }
}

/// The shell: one screen above, the tab bar below.
///
/// **The tab bar is honest** (FR15 §5.5). Home, Pipeline and Tasks are shown
/// and visibly disabled, not hidden: a first build that hides them feels
/// finished when it is a third of an app, and someone who meets the other tabs
/// later has learned the app twice. They arrive in FR16.
struct MainShell: View {
    var body: some View {
        VStack(spacing: 0) {
            NotesView()
            TabBar()
        }
        .background(Color.appBackground)
    }
}

struct TabBar: View {
    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let enabled: Bool
    }

    private let items = [
        Item(id: "Home", symbol: "house", enabled: false),
        Item(id: "Pipeline", symbol: "chart.bar", enabled: false),
        Item(id: "Notes", symbol: "mic", enabled: true),
        Item(id: "Tasks", symbol: "checklist", enabled: false)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 3) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(item.enabled ? Color.amber : Color.ink3)
                    Text(item.id)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.enabled ? Color.amber600 : Color.ink3)
                }
                .opacity(item.enabled ? 1 : 0.45)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item.enabled ? [.isButton, .isSelected] : [.isButton])
                .accessibilityHint(item.enabled ? "" : "Not available yet")
                .disabled(!item.enabled)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 4)
        .background(Color.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.border2).frame(height: 1) }
    }
}

/// The white strip at the top of a screen, with its title.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.display(19))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border2).frame(height: 1) }
    }
}
