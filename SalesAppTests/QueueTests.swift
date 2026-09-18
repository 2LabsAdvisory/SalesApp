import Foundation
import Testing
@testable import SalesApp

/// The outbound queue (FR15 §5.3): a note said with no signal is saved, kept
/// through a restart, sent in the order it was said, and never discarded.
@Suite struct QueueTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NoteQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func note(_ body: String, at offset: TimeInterval, user: String? = "u1", org: String? = "o1") -> QueuedNote {
        QueuedNote(
            id: UUID(), body: body, source: .siri,
            capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + offset),
            userId: user, organizationId: org, organizationName: "Kestrel Systems")
    }

    @Test func survivesARestart() async throws {
        let first = NoteQueue(directory: directory)
        try await first.add(note("Coffee with Priya", at: 0))

        // A new queue over the same file is what a relaunch after force-quit
        // or reboot sees.
        let relaunched = NoteQueue(directory: directory)
        let notes = await relaunched.all()
        #expect(notes.map(\.body) == ["Coffee with Priya"])
        #expect(notes.first?.state == .waiting)
    }

    @Test func sendsInTheOrderSaid() async throws {
        let queue = NoteQueue(directory: directory)
        // Added out of order: the queue orders by when each was said.
        try await queue.add(note("second", at: 60))
        try await queue.add(note("first", at: 0))
        try await queue.add(note("third", at: 120))

        var sent: [String] = []
        while let next = try await queue.claimNext() {
            #expect(try await queue.claimNext() == nil, "a second note went out while one was in flight")
            sent.append(next.body)
            try await queue.remove(next.id)
        }
        #expect(sent == ["first", "second", "third"])
    }

    @Test func aFailedNoteIsKeptAndDoesNotBlockTheRest() async throws {
        let queue = NoteQueue(directory: directory)
        let refused = note("refused", at: 0)
        try await queue.add(refused)
        try await queue.add(note("next", at: 10))

        _ = try await queue.claimNext()
        try await queue.update(refused.id) { $0.state = .failed("A note cannot be empty.") }

        #expect(try await queue.claimNext()?.body == "next")
        let kept = await queue.note(refused.id)
        #expect(kept?.state == .failed("A note cannot be empty."), "a failed note was dropped")
    }

    @Test func anUploadLostToAForceQuitGoesBackToWaiting() async throws {
        let queue = NoteQueue(directory: directory)
        let inFlight = note("in flight", at: 0)
        try await queue.add(inFlight)
        _ = try await queue.claimNext()

        // The system has no task for it any more.
        try await queue.resetInFlight(except: [])
        #expect(await queue.note(inFlight.id)?.state == .waiting)
    }

    @Test func aNoteSaidBeforeSignInIsAdoptedByTheFirstSignIn() async throws {
        let queue = NoteQueue(directory: directory)
        let unowned = note("said before signing in", at: 0, user: nil, org: nil)
        let owned = note("someone else's", at: 1, user: "other", org: "o2")
        try await queue.add(unowned)
        try await queue.add(owned)

        try await queue.adoptUnowned(userId: "u1", organizationId: "o1", organizationName: "Kestrel Systems")

        #expect(await queue.note(unowned.id)?.userId == "u1")
        #expect(await queue.note(unowned.id)?.organizationId == "o1")
        #expect(await queue.note(owned.id)?.userId == "other", "a note already owned changed hands")
    }

    @Test func onlyTextIsStored() async throws {
        let queue = NoteQueue(directory: directory)
        try await queue.add(note("words only", at: 0))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["queue.json"])
    }

    @Test func captureSavesBeforeSendingAndKeepsTheOrgOfTheMoment() async throws {
        let queue = NoteQueue(directory: directory)
        let tokens = TokenStore(account: "test-\(UUID().uuidString)")
        defer { Task { await tokens.clear() } }
        var credentials = Credentials(bundle: .sample)
        credentials.userId = "u1"
        credentials.organizationId = "kestrel"
        credentials.organizationName = "Kestrel Systems"
        try await tokens.save(credentials)

        let sawNoteWhenSending = SendProbe()
        let capture = CaptureService(queue: queue, tokens: tokens) {
            await sawNoteWhenSending.record(await queue.all().count)
        }

        let outcome = try await capture.capture("  Dave wants pricing.  ", source: .appRecorder)
        #expect(outcome == .saved(organizationName: "Kestrel Systems"))
        #expect(await sawNoteWhenSending.value == 1, "sending started before the note was saved")

        let saved = try #require(await queue.all().first)
        #expect(saved.body == "Dave wants pricing.")
        #expect(saved.source == .appRecorder)
        #expect(saved.organizationId == "kestrel")
    }

    @Test func nothingSaidIsNothingSaved() async throws {
        let queue = NoteQueue(directory: directory)
        let capture = CaptureService(queue: queue, tokens: TokenStore(account: "test-\(UUID().uuidString)")) {}
        #expect(try await capture.capture("   \n ", source: .siri) == .nothingHeard)
        #expect(await queue.all().isEmpty)
    }

    @Test func signedOutCaptureIsStillKept() async throws {
        let queue = NoteQueue(directory: directory)
        let capture = CaptureService(queue: queue, tokens: TokenStore(account: "test-\(UUID().uuidString)")) {}
        #expect(try await capture.capture("Kembridge, new year", source: .siri) == .savedAwaitingSignIn)
        #expect(await queue.all().count == 1, "a note said while signed out was not taken")
    }
}

actor SendProbe {
    private(set) var value = 0
    func record(_ count: Int) { value = count }
}

extension TokenBundle {
    static var sample: TokenBundle {
        let json = """
        {"access_token":"access","access_expires_at":"2026-09-18T18:30:00.000Z",
         "refresh_token":"refresh","refresh_expires_at":"2026-10-18T18:15:00.000Z",
         "device":{"id":"d1","name":"Test iPhone","platform":"ios"}}
        """
        return try! JSONDecoder.api.decode(TokenBundle.self, from: Data(json.utf8))
    }
}
