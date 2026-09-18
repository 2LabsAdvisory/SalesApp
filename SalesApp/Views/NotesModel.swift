import Foundation
import Observation

/// The Notes tab: what is still on the phone, and what the server has.
@MainActor
@Observable
final class NotesModel {
    private(set) var queued: [QueuedNote] = []
    private(set) var notes: [Note] = []
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var loadError: String?

    private let services: AppServices
    private var observer: NSObjectProtocol?
    private var lastQueuedIds: Set<UUID> = []

    init(services: AppServices = .shared) {
        self.services = services
    }

    /// The server's list, split the way FR06 §5.3 orders it: what needs a
    /// look first, then everything else by recency.
    var needingAttention: [Note] { notes.filter { $0.status.needsAttention } }
    var earlier: [Note] { notes.filter { !$0.status.needsAttention } }
    var canLoadMore: Bool { notes.count < total }

    func start() async {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NoteQueue.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.queueChanged() }
            }
        }
        await queueChanged()
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await services.api.notes(offset: 0)
            notes = page.data
            total = page.total
            loadError = nil
        } catch let error as APIError {
            // Offline is not an error worth shouting about: the list simply
            // shows what it last had, and the queue shows what is waiting.
            loadError = error == .offline ? nil : error.message
        } catch {
            loadError = APIError.invalidResponse.message
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await services.api.notes(offset: notes.count) {
            let known = Set(notes.map(\.id))
            notes += page.data.filter { !known.contains($0.id) }
            total = page.total
        }
    }

    func retry(_ note: QueuedNote) async {
        await services.sender.retry(note.id)
    }

    /// When a note leaves the queue it has reached the server, so the list
    /// is fetched again to show it there.
    private func queueChanged() async {
        queued = await services.queue.all()
        let ids = Set(queued.map(\.id))
        let departed = !lastQueuedIds.subtracting(ids).isEmpty
        lastQueuedIds = ids
        if departed { await reload() }
    }
}

// MARK: - How a note reads in a list

enum NoteFormat {
    /// "2:14p" today, "Yesterday", then "Aug 12" — as the prototype writes it.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "%d:%02d%@", twelve, minute, hour < 12 ? "a" : "p")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What the note did, which is the question a seller has about it (FR06 §5.3).
    static func subtitle(for note: Note, now: Date = Date()) -> String {
        [when(note.saidAt, now: now), note.outcome].compactMap { $0 }.joined(separator: " · ")
    }

    static func subtitle(for note: QueuedNote, now: Date = Date()) -> String {
        let state = switch note.state {
        case .waiting: "queued"
        case .sending: "sending"
        case .failed: "not sent"
        }
        return "\(when(note.capturedAt, now: now)) · \(state)"
    }

    /// The first words, quoted, as the offline frame shows them.
    static func excerpt(_ body: String, limit: Int = 60) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return "“\(flat)”" }
        let cut = flat.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return "“\(trimmed)…”"
    }
}
