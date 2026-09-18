import Foundation

/// Everything this phone holds to act as its person: the device's tokens and
/// the organization it is working in. Stored as one Keychain item.
struct Credentials: Codable, Sendable, Equatable {
    var accessToken: String
    var accessExpiresAt: Date
    var refreshToken: String
    var refreshExpiresAt: Date
    var deviceId: String
    var deviceName: String

    // Filled from /api/me after sign-in. Not secrets, but they belong with the
    // session they describe: signing out forgets them together.
    var userId: String?
    var userName: String?
    var userEmail: String?
    var organizationId: String?
    var organizationName: String?

    init(bundle: TokenBundle) {
        accessToken = bundle.accessToken
        accessExpiresAt = bundle.accessExpiresAt
        refreshToken = bundle.refreshToken
        refreshExpiresAt = bundle.refreshExpiresAt
        deviceId = bundle.device.id
        deviceName = bundle.device.name
    }

    mutating func apply(_ bundle: TokenBundle) {
        accessToken = bundle.accessToken
        accessExpiresAt = bundle.accessExpiresAt
        refreshToken = bundle.refreshToken
        refreshExpiresAt = bundle.refreshExpiresAt
    }
}

/// The session on this phone, one at a time.
///
/// An actor so a Siri capture, the background sender and the screens can all
/// ask for a token at once without two refreshes racing: a refresh rotates the
/// refresh token, and the server treats a second use of a spent one as theft
/// (Sales-Functions deviceStore.refreshDevice).
actor TokenStore {
    static let didChange = Notification.Name("ca.2labs.sales.credentialsDidChange")

    private let account: String
    private var cached: Credentials?
    private var loaded = false
    private var refreshing: Task<Credentials, Error>?

    init(account: String = "device-session") {
        self.account = account
    }

    func current() -> Credentials? {
        if !loaded {
            cached = (try? Keychain.read(account)).flatMap { try? JSONDecoder.api.decode(Credentials.self, from: $0) }
            loaded = true
        }
        return cached
    }

    func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder.api.encode(credentials)
        try Keychain.write(data, account: account)
        cached = credentials
        loaded = true
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func update(_ change: @Sendable (inout Credentials) -> Void) throws {
        guard var credentials = current() else { return }
        change(&credentials)
        try save(credentials)
    }

    func clear() {
        try? Keychain.delete(account)
        cached = nil
        loaded = true
        refreshing = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Rotate the tokens, once, however many callers ask at the same moment.
    func refresh(using exchange: @escaping @Sendable (String) async throws -> TokenBundle) async throws -> Credentials {
        if let refreshing { return try await refreshing.value }
        guard let credentials = current() else { throw APIError.signedOut }

        let task = Task { () throws -> Credentials in
            let bundle = try await exchange(credentials.refreshToken)
            var next = credentials
            next.apply(bundle)
            return next
        }
        refreshing = task
        defer { refreshing = nil }

        do {
            let next = try await task.value
            // Signed out while the refresh was in the air: do not resurrect it.
            guard current() != nil else { throw APIError.signedOut }
            try save(next)
            return next
        } catch APIError.signedOut {
            clear()
            throw APIError.signedOut
        }
    }
}
