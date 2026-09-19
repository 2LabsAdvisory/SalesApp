import Foundation

/// A note said on this phone and not yet confirmed by the server.
struct QueuedNote: Codable, Sendable, Identifiable, Equatable {
    enum State: Codable, Sendable, Equatable {
        /// Waiting for signal, or for its turn.
        case waiting
        /// Handed to the system to upload.
        case sending
        /// The server refused it for good. Kept on the phone and shown, never
        /// dropped (FR15 §5.3).
        case failed(String)
    }

    /// Minted when the note is captured and sent on every attempt, so a retry
    /// after a lost answer finds the first note instead of making a second.
    let id: UUID
    let body: String
    let source: NoteSource
    let capturedAt: Date

    /// Who said it and which organization it belongs to, fixed at capture:
    /// the org selected at the time is the one it lands in (FR15 §7, §8
    /// decision 2). Nil only if nobody was signed in yet — the next sign-in
    /// adopts it.
    var userId: String?
    var organizationId: String?
    var organizationName: String?
    /// The deal it was said about, when it was taken from a deal (FR16 §4.4).
    /// Checked against the organization by the server, like any link.
    var opportunityId: String?

    var state: State = .waiting
    var attempts: Int = 0
    var lastSentAt: Date?
}

/// The outbound queue (FR15 §5.3). **Outbound only** — nothing here caches the
/// pipeline.
///
/// Stored as a file with `completeUntilFirstUserAuthentication` protection:
/// readable and writable while the phone is locked, which is exactly when
/// Siri captures (FR15 §8, decision 3), but encrypted at rest from a cold boot
/// until the first unlock. It survives force-quit and reboot because it is a
/// file, not memory.
///
/// Only text is ever written here. There is no audio in this app to write.
actor NoteQueue {
    static let didChange = Notification.Name("ca.2labs.sales.noteQueueDidChange")

    private let fileURL: URL
    private var notes: [QueuedNote] = []
    private var loaded = false

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "NoteQueue", directoryHint: .isDirectory)
        self.fileURL = base.appending(path: "queue.json")
    }

    var directory: URL { fileURL.deletingLastPathComponent() }

    // MARK: Reading

    func all() -> [QueuedNote] {
        load()
        return notes
    }

    /// The next note to send: the earliest captured that is waiting — but only
    /// when nothing is already on its way, so notes arrive in the order they
    /// were said.
    func next() -> QueuedNote? {
        load()
        guard !notes.contains(where: { $0.state == .sending }) else { return nil }
        return notes.first { $0.state == .waiting }
    }

    /// Take the next note and mark it as sending, in one step, so two callers
    /// can never both send it.
    func claimNext() throws -> QueuedNote? {
        guard let note = next() else { return nil }
        try update(note.id) { $0.state = .sending }
        return self.note(note.id)
    }

    func note(_ id: UUID) -> QueuedNote? {
        load()
        return notes.first { $0.id == id }
    }

    // MARK: Writing

    func add(_ note: QueuedNote) throws {
        load()
        notes.append(note)
        notes.sort { $0.capturedAt < $1.capturedAt }
        try persist()
    }

    func update(_ id: UUID, _ change: (inout QueuedNote) -> Void) throws {
        load()
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        try persist()
    }

    /// The server has it. Only now does it leave the phone.
    func remove(_ id: UUID) throws {
        load()
        notes.removeAll { $0.id == id }
        try persist()
    }

    /// A note captured before anyone signed in is adopted by the first sign-in.
    func adoptUnowned(userId: String, organizationId: String, organizationName: String?) throws {
        load()
        var changed = false
        for index in notes.indices where notes[index].userId == nil {
            notes[index].userId = userId
            notes[index].organizationId = organizationId
            notes[index].organizationName = organizationName
            changed = true
        }
        if changed { try persist() }
    }

    /// After a force-quit or a reboot the system has dropped any upload that
    /// was in flight. Anything still marked as sending goes back to waiting.
    func resetInFlight(except live: Set<UUID>) throws {
        load()
        var changed = false
        for index in notes.indices where notes[index].state == .sending && !live.contains(notes[index].id) {
            notes[index].state = .waiting
            changed = true
        }
        if changed { try persist() }
    }

    // MARK: Storage

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        notes = (try? JSONDecoder.api.decode([QueuedNote].self, from: data)) ?? []
    }

    private func persist() throws {
        try Self.prepare(directory)
        let data = try JSONEncoder.api.encode(notes)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The directory is created with the same protection as its files, and
    /// kept out of iCloud backup: a queued note is on its way to the server,
    /// and a restored copy on another phone would send it a second time under
    /// a session that is not there.
    static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
    }
}
