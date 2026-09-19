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

/// The shell: one screen above, the tab bar below. Today is where the app
/// opens (FR16 §4.1). Every tab stays alive when another is showing, so going
/// back to one finds it where it was left.
struct MainShell: View {
    enum Tab: String, CaseIterable, Identifiable {
        case today = "Today", pipeline = "Pipeline", notes = "Notes", tasks = "Tasks"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .today: "house"
            case .pipeline: "chart.bar"
            case .notes: "mic"
            case .tasks: "checklist"
            }
        }
    }

    @State private var tab: Tab = .today

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                screen(.today) { TodayView() }
                screen(.pipeline) { PipelineView() }
                screen(.notes) { NotesView() }
                screen(.tasks) { TasksView() }
            }
            TabBar(selection: $tab)
        }
        .background(Color.appBackground)
    }

    private func screen<Content: View>(_ which: Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(tab == which ? 1 : 0)
            .allowsHitTesting(tab == which)
            .accessibilityHidden(tab != which)
    }
}

struct TabBar: View {
    @Binding var selection: MainShell.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainShell.Tab.allCases) { item in
                let on = selection == item
                Button { selection = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(on ? Color.amber : Color.ink3)
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(on ? Color.amber600 : Color.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
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
