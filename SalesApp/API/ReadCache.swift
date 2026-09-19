import CryptoKit
import Foundation

/// What a screen shows, and whether it is live.
struct Loaded<Value: Sendable>: Sendable {
    let value: Value
    /// When the cached copy was taken. Nil means it came from the server just
    /// now; anything else is a photograph and the screen says so.
    let asOf: Date?

    var isLive: Bool { asOf == nil }
}

/// The last successful load of each screen, kept for reading without signal
/// (FR16 §5.6, ratified in §8).
///
/// **A photograph, not a sync engine.** Only server answers are stored, byte
/// for byte, and only reads. Nothing here is ever edited locally, merged, or
/// sent back: every write on these screens needs a connection, and the only
/// offline write in the product remains a captured note, which has its own
/// queue.
///
/// Filed under the organization, so switching org reads that org's own
/// photograph (or fetches), never a filtered superset. Forgotten entirely on
/// sign-out. Protected like the note queue — readable after first unlock —
/// and kept out of backups.
actor ReadCache {
    private let root: URL

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ReadCache", directoryHint: .isDirectory)
    }

    private func file(org: String, key: String) -> URL {
        // Keys carry query strings; a hash makes a safe, fixed-length name.
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: org, directoryHint: .isDirectory).appending(path: "\(name).json")
    }

    func save(_ data: Data, org: String, key: String) {
        let url = file(org: org, key: key)
        do {
            try NoteQueue.prepare(root)
            try NoteQueue.prepare(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A cache that cannot be written is only a slower next launch.
        }
    }

    func load(org: String, key: String) -> (data: Data, savedAt: Date)? {
        let url = file(org: org, key: key)
        guard let data = try? Data(contentsOf: url),
              let saved = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return (data, saved)
    }

    /// Forget everything — on sign-out, and when the session ends from afar.
    func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension APIClient {
    /// A read that falls back to the last good answer when there is no
    /// signal. Any other failure is shown as a failure — a photograph only
    /// stands in for a connection, never for an error.
    func read<T: Decodable & Sendable>(
        _ type: T.Type,
        _ path: String,
        query: [URLQueryItem] = [],
        cache: ReadCache
    ) async throws -> Loaded<T> {
        guard let org = await tokens.current()?.organizationId else { throw APIError.signedOut }
        let key = url(path, query: query).absoluteString

        do {
            let (data, _) = try await send("GET", path, query: query)
            let value = try decode(type, from: data)
            await cache.save(data, org: org, key: key)
            return Loaded(value: value, asOf: nil)
        } catch APIError.offline {
            guard let cached = await cache.load(org: org, key: key),
                  let value = try? decode(type, from: cached.data)
            else { throw APIError.offline }
            return Loaded(value: value, asOf: cached.savedAt)
        }
    }
}
