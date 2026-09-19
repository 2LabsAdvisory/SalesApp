import Foundation

/// The one way a spoken note enters the app.
///
/// Siri and the in-app mic both end here, so the two produce the same note —
/// same fields, same queue, same result (FR15 §7). Only `source` differs,
/// because the web app's Notes tab says where each note came from.
///
/// The note is saved to the queue before anything touches the network. From
/// that moment it exists, whatever the signal.
struct CaptureService: Sendable {
    enum Outcome: Sendable, Equatable {
        /// Saved on the phone, on its way to the org named.
        case saved(organizationName: String?)
        /// Saved, but nobody is signed in: it goes up after the next sign-in.
        case savedAwaitingSignIn
        /// Nothing was said, so nothing was saved.
        case nothingHeard
    }

    let queue: NoteQueue
    let tokens: TokenStore
    /// Starts sending. The background sender in the app; nothing in tests.
    let send: @Sendable () async -> Void

    func capture(
        _ text: String, source: NoteSource, about opportunityId: String? = nil, at capturedAt: Date = Date()
    ) async throws -> Outcome {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .nothingHeard }

        // The org this note belongs to is decided now, not when it sends: the
        // one selected at the moment it was said (FR15 §8, decision 2).
        let credentials = await tokens.current()
        let note = QueuedNote(
            id: UUID(),
            body: body,
            source: source,
            capturedAt: capturedAt,
            userId: credentials?.userId,
            organizationId: credentials?.organizationId,
            organizationName: credentials?.organizationName,
            opportunityId: opportunityId)
        try await queue.add(note)

        await send()
        return credentials?.userId == nil ? .savedAwaitingSignIn : .saved(organizationName: credentials?.organizationName)
    }
}
