import SwiftUI

/// The gate on resume (FR15 §3.3). A CRM is a list of who your customers are
/// and what they pay; an unlocked phone on a café table should not spill it.
///
/// It covers the screen as soon as the app leaves the foreground, so the app
/// switcher's snapshot shows this rather than the notes.
struct LockView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandMark(size: 44)
            Text("Sales is locked")
                .font(.display(19))
                .foregroundStyle(Color.ink)
            Button("Unlock") { Task { await app.unlock() } }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .task(id: scenePhase) {
            if scenePhase == .active { await app.unlockAutomatically() }
        }
    }
}
