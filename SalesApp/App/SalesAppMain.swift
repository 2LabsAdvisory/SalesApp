import SwiftUI
import UIKit

@main
struct SalesAppMain: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                app.sceneMovedToBackground()
            case .active:
                // Coming back is a good moment to send anything still waiting.
                Task { await app.services.sender.pump() }
            default:
                break
            }
        }
    }
}

/// Only here to hear from the system about background uploads: when a queued
/// note finishes sending while the app was not running, iOS relaunches it in
/// the background and hands over a completion handler to call once the
/// answers have been read.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == NoteSender.sessionIdentifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let handler = completionHandler
        // Touching `shared` recreates the session with this identifier, which
        // is what reconnects it to the uploads the system finished.
        AppServices.shared.sender.setBackgroundCompletion { handler() }
    }
}
