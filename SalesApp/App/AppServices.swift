import Foundation

/// The long-lived pieces, shared by the screens and by the Siri intent.
///
/// App Intents in the app target run in the app's own process, so Siri and
/// the screens see the same token store, the same queue and the same sender —
/// one background session, one queue file, one session in the Keychain.
final class AppServices: Sendable {
    static let shared = AppServices()

    let tokens: TokenStore
    let api: APIClient
    let queue: NoteQueue
    let sender: NoteSender
    let capture: CaptureService

    private init() {
        tokens = TokenStore()
        api = APIClient(tokens: tokens)
        queue = NoteQueue()
        let noteSender = NoteSender(queue: queue, api: api)
        sender = noteSender
        capture = CaptureService(queue: queue, tokens: tokens, send: { await noteSender.pump() })
    }
}
