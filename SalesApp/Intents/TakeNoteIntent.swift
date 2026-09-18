import AppIntents

/// "Hey Siri, take a 2Labs note" (FR15 §5.1).
///
/// The bar: it works **with the phone locked, the app not running, and the
/// screen never looked at**. So the intent never opens the app, runs without
/// unlocking (`authenticationPolicy = .alwaysAllowed`), and does nothing but
/// save the note to the queue — which is readable while locked — and hand it
/// to the background sender.
///
/// Siri's answer is one short sentence. It does not read the note back and it
/// does not ask which customer it was about; the sorting out happens later, on
/// a screen, when the seller is sitting down.
///
/// The Face ID gate never applies here (FR15 §8, decision 3): it guards
/// reading the app, not writing a note into it.
struct TakeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a note"
    static let description = IntentDescription(
        "Say what happened. It's saved to Sales and sent when you have signal.")

    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Note", requestValueDialog: IntentDialog("What happened?"))
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await AppServices.shared.capture.capture(text, source: .siri)
        return .result(dialog: IntentDialog(stringLiteral: Self.reply(to: outcome)))
    }

    static func reply(to outcome: CaptureService.Outcome) -> String {
        switch outcome {
        case .saved: "Saved — it'll reach Sales on its own."
        case .savedAwaitingSignIn: "Saved on your phone — sign in to Sales and it'll go up."
        case .nothingHeard: "I didn't catch anything, so nothing was saved."
        }
    }
}

/// The phrases Siri listens for, with no setup by the user. "2Labs" is
/// registered as an alternative app name in Info.plist, so "take a 2Labs note"
/// resolves to this app.
struct SalesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakeNoteIntent(),
            phrases: [
                "Take a \(.applicationName) note",
                "Take a note in \(.applicationName)",
                "New \(.applicationName) note"
            ],
            shortTitle: "Take a note",
            systemImageName: "mic")
    }
}
