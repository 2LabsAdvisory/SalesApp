import Foundation
import os

/// Gets queued notes to the server (FR15 §5.3).
///
/// Each note goes up as a **background upload**, so the system carries it even
/// when this app is suspended or not running: a note said in a car park with
/// no bars is handed to iOS, which sends it when signal returns, with nobody
/// touching the phone. When the upload finishes the system wakes the app to
/// hear the answer.
///
/// One note is in flight at a time, so notes arrive in the order they were
/// said. Every attempt carries the note's `client_id`, so a retry after a lost
/// answer finds the first note on the server instead of making a second.
///
/// A note leaves the queue only when the server confirms it. Anything else
/// leaves it waiting, or — if the server refuses it for good — marked failed
/// and still on the phone.
final class NoteSender: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "ca.2labs.sales.note-uploads"

    private let queue: NoteQueue
    private let api: APIClient
    private let log = Logger(subsystem: "ca.2labs.sales", category: "NoteSender")

    // Mutable state touched from URLSession's delegate queue and from tasks,
    // always under the lock.
    private let state = OSAllocatedUnfairLock(initialState: MutableState())
    private struct MutableState {
        var responses: [Int: Data] = [:]
        var backgroundCompletion: (@Sendable () -> Void)?
    }

    private var session: URLSession!

    init(queue: NoteQueue, api: APIClient) {
        self.queue = queue
        self.api = api
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private var uploadsDirectory: URL {
        get async { await queue.directory.appending(path: "uploads", directoryHint: .isDirectory) }
    }

    // MARK: Driving the queue

    /// At launch: the system drops in-flight uploads on a force-quit, so any
    /// note still marked as sending without a live upload goes back to waiting.
    func reconcile() async {
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
        try? await queue.resetInFlight(except: live)
        await pump()
    }

    /// Send the next note, if there is one and nothing else is on its way.
    /// Safe to call from anywhere, as often as you like.
    func pump() async {
        guard let credentials = await api.tokens.current() else { return }   // waits for sign-in
        guard let note = try? await queue.claimNext() else { return }

        if let owner = note.userId, owner != credentials.userId {
            // Said while someone else was signed in on this phone. Sending it
            // under this session would put their words in another person's
            // name, so it stays here, visibly, for them.
            try? await queue.update(note.id) {
                $0.state = .failed("Said while someone else was signed in. It stays on this phone.")
            }
            await pump()
            return
        }

        guard let organizationId = note.organizationId ?? credentials.organizationId else {
            try? await queue.update(note.id) { $0.state = .waiting }
            return
        }

        let token: String
        do {
            token = try await api.accessTokenForUpload()
        } catch {
            try? await queue.update(note.id) { $0.state = .waiting }
            return
        }

        do {
            let file = try await writeBody(for: note)
            var request = URLRequest(url: api.url("notes"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // An assertion, not an input: if the session is now in another
            // org the server refuses with 409 rather than filing it there.
            request.setValue(organizationId, forHTTPHeaderField: "X-Sales-Organization")

            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = note.id.uuidString
            if note.attempts > 0 {
                task.earliestBeginDate = Date(timeIntervalSinceNow: Self.backoff(afterAttempts: note.attempts))
            }
            try await queue.update(note.id) {
                $0.attempts += 1
                $0.lastSentAt = Date()
            }
            task.resume()
        } catch {
            log.error("Could not start an upload: \(error.localizedDescription, privacy: .public)")
            try? await queue.update(note.id) { $0.state = .waiting }
        }
    }

    /// Put a failed note back in line, at the user's request.
    func retry(_ id: UUID) async {
        try? await queue.update(id) {
            $0.state = .waiting
            $0.attempts = 0
        }
        await pump()
    }

    /// 15s, 30s, 1m, 2m … capped at 30 minutes. Applied by the system to the
    /// next upload, so it holds even while the app is not running.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(15 * pow(2, Double(max(0, attempts - 1))), 30 * 60)
    }

    // MARK: The body on disk

    /// A background upload must come from a file. It holds the text and the
    /// ids — never audio — with the same protection as the queue, and is
    /// removed as soon as the upload finishes.
    private func writeBody(for note: QueuedNote) async throws -> URL {
        struct Body: Encodable {
            let body: String
            let source: NoteSource
            let clientId: String
            let capturedAt: Date
            let opportunityId: String?
        }
        let directory = await uploadsDirectory
        try NoteQueue.prepare(directory)
        let file = directory.appending(path: "\(note.id.uuidString).json")
        let data = try JSONEncoder.api.encode(Body(
            body: note.body, source: note.source, clientId: note.id.uuidString.lowercased(),
            capturedAt: note.capturedAt, opportunityId: note.opportunityId))
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }

    private func removeBody(for id: UUID) async {
        let file = await uploadsDirectory.appending(path: "\(id.uuidString).json")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Answers

    private func finish(_ id: UUID, status: Int?, data: Data, error: Error?) async {
        await removeBody(for: id)
        guard let note = await queue.note(id) else { return }

        guard let status, error == nil else {
            // No answer at all. The note waits; pump again and the system
            // holds the next attempt until the backoff and the signal allow.
            log.info("Upload ended without an answer: \(error?.localizedDescription ?? "none", privacy: .public)")
            try? await queue.update(id) { $0.state = .waiting }
            await pump()
            return
        }

        do {
            _ = try APIClient.check(status: status, data: data)
            try? await queue.remove(id)
            await restoreChosenOrganization(after: note)
        } catch APIError.organizationChanged {
            await moveToOrganization(of: note)
        } catch APIError.http(401, _) {
            // The token lapsed while the note waited for signal. There is
            // signal now, so refresh and go again; if the device itself has
            // ended, the note waits for the next sign-in.
            _ = try? await api.refresh()
            try? await queue.update(id) { $0.state = .waiting }
        } catch APIError.http(let code, let message) where code == 429 || code >= 500 {
            log.info("Server answered \(code), will retry: \(message, privacy: .public)")
            try? await queue.update(id) { $0.state = .waiting }
        } catch APIError.http(_, let message) {
            // Refused for good. Kept, and shown, never discarded.
            try? await queue.update(id) { $0.state = .failed(message) }
        } catch {
            try? await queue.update(id) { $0.state = .waiting }
        }
        await pump()
    }

    /// The session moved to another org between capture and sending. The note
    /// belongs to the org it was said in, so the session goes to the note —
    /// through switch-org, which checks membership — and not the other way.
    private func moveToOrganization(of note: QueuedNote) async {
        guard let target = note.organizationId else {
            try? await queue.update(note.id) { $0.state = .waiting }
            return
        }
        do {
            try await api.switchOrganization(to: target)
            try? await queue.update(note.id) { $0.state = .waiting }
        } catch APIError.http(403, _) {
            let name = note.organizationName ?? "that organization"
            try? await queue.update(note.id) {
                $0.state = .failed("You no longer have access to \(name). The note stays on this phone.")
            }
        } catch {
            try? await queue.update(note.id) { $0.state = .waiting }
        }
    }

    /// After sending a note into an org other than the one chosen in the app,
    /// put the session back where the person left it.
    private func restoreChosenOrganization(after note: QueuedNote) async {
        guard let chosen = await api.tokens.current()?.organizationId,
              let sentTo = note.organizationId, sentTo != chosen else { return }
        let nextInSameOrg = await queue.all().contains { $0.state == .waiting && $0.organizationId == sentTo }
        if !nextInSameOrg { try? await api.switchOrganization(to: chosen) }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.responses[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = state.withLock { $0.responses.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { await finish(id, status: status, data: data, error: error) }
    }

    // MARK: Waking in the background

    func setBackgroundCompletion(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.backgroundCompletion = handler }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.backgroundCompletion = nil }
            return state.backgroundCompletion
        }
        DispatchQueue.main.async { handler?() }
    }
}
