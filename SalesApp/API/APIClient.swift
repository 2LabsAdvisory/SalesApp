import Foundation

enum APIError: Error, Equatable, Sendable {
    /// No signal, or the server could not be reached.
    case offline
    /// The device's session has ended: signed out, revoked, or expired.
    case signedOut
    /// The session is in a different organization from the one the caller
    /// asserted with X-Sales-Organization.
    case organizationChanged
    case http(status: Int, message: String)
    case invalidResponse

    var message: String {
        switch self {
        case .offline: "No signal. Try again when you're connected."
        case .signedOut: "You've been signed out. Please sign in again."
        case .organizationChanged: "You're now working in a different organization."
        case .http(_, let message): message
        case .invalidResponse: "Sales sent back something unexpected. Please try again."
        }
    }
}

/// The Sales API, as a phone calls it (FR15 §3.2).
///
/// The same endpoints the web app uses, through the same `withAuth` seam. The
/// only difference is the transport: a device access token in an
/// `Authorization: Bearer` header. Cookies are switched off entirely — the API
/// refuses a request carrying both, and this app has no business holding one.
///
/// This client never sends an organization id as an input. The session's
/// active org is the only source (ARCHITECTURE.md §5.1); `expectOrganization`
/// is an assertion the server checks, and a mismatch is refused, never obeyed.
final class APIClient: Sendable {
    let baseURL: URL
    let tokens: TokenStore
    private let session: URLSession

    init(baseURL: URL = AppConfig.apiBaseURL, tokens: TokenStore) {
        self.baseURL = baseURL
        self.tokens = tokens
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: Requests

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// Sends a request and returns the raw body of a 2xx answer. Authorized
    /// requests carry the device token, refreshing it first if it is about to
    /// lapse, and retry once after a 401 with a fresh one.
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        authorized: Bool = true,
        expectOrganization: String? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.api.encode(body)
        }
        if let expectOrganization {
            request.setValue(expectOrganization, forHTTPHeaderField: "X-Sales-Organization")
        }

        guard authorized else { return try await perform(request) }

        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        do {
            return try await perform(request)
        } catch APIError.http(401, _) {
            let fresh = try await refresh()
            request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
            do {
                return try await perform(request)
            } catch APIError.http(401, _) {
                throw APIError.signedOut
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder.api.decode(type, from: data) } catch { throw APIError.invalidResponse }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return try Self.check(status: http.statusCode, data: data)
    }

    /// Maps an answer to success or a typed failure. Shared with the
    /// background sender, which gets its answers from a delegate instead.
    static func check(status: Int, data: Data) throws -> (Data, Int) {
        if (200..<300).contains(status) { return (data, status) }
        let body = try? JSONDecoder.api.decode(ErrorBody.self, from: data)
        if status == 409, body?.code == "organization_changed" { throw APIError.organizationChanged }
        throw APIError.http(status: status, message: body?.error ?? "Something went wrong (\(status)).")
    }

    // MARK: The device session

    /// A usable access token, refreshed first if it lapses within a minute.
    func accessToken() async throws -> String {
        guard let credentials = await tokens.current() else { throw APIError.signedOut }
        if credentials.accessExpiresAt.timeIntervalSinceNow > 60 { return credentials.accessToken }
        return try await refresh().accessToken
    }

    /// The token for a background upload. If the phone has no signal to
    /// refresh with, the current token goes anyway: the upload waits for
    /// signal, and if the token has lapsed by then the server answers 401 and
    /// the sender refreshes and tries again — with signal, this time.
    func accessTokenForUpload() async throws -> String {
        do {
            return try await accessToken()
        } catch APIError.offline {
            guard let credentials = await tokens.current() else { throw APIError.signedOut }
            return credentials.accessToken
        }
    }

    @discardableResult
    func refresh() async throws -> Credentials {
        try await tokens.refresh { [self] refreshToken in
            do {
                let (data, _) = try await send(
                    "POST", "auth/device/refresh",
                    body: ["refresh_token": refreshToken], authorized: false)
                return try decode(DataEnvelope<TokenBundle>.self, from: data).data
            } catch APIError.http(401, _) {
                throw APIError.signedOut
            }
        }
    }
}

// MARK: - Endpoints

struct DeviceDescription: Encodable, Sendable {
    let name: String
    let platform = "ios"
}

extension APIClient {
    /// Ask for an emailed code. The server answers the same whether or not the
    /// address has an account.
    func requestCode(email: String) async throws {
        _ = try await send("POST", "auth/request-code", body: ["email": email], authorized: false)
    }

    func verifyCode(email: String, code: String, device: DeviceDescription) async throws -> TokenBundle {
        struct Body: Encodable, Sendable { let email: String; let code: String; let device: DeviceDescription }
        let (data, _) = try await send(
            "POST", "auth/device/verify-code",
            body: Body(email: email, code: code, device: device), authorized: false)
        return try decode(DataEnvelope<TokenBundle>.self, from: data).data
    }

    func exchangeMicrosoftCode(_ code: String, verifier: String, device: DeviceDescription) async throws -> TokenBundle {
        struct Body: Encodable, Sendable { let code: String; let codeVerifier: String; let device: DeviceDescription }
        let (data, _) = try await send(
            "POST", "auth/device/exchange",
            body: Body(code: code, codeVerifier: verifier, device: device), authorized: false)
        return try decode(DataEnvelope<TokenBundle>.self, from: data).data
    }

    /// Where Microsoft sign-in starts for a phone. The challenge is ours; the
    /// verifier never leaves the phone.
    func microsoftStartURL(challenge: String) -> URL {
        url("auth/microsoft/start", query: [URLQueryItem(name: "device_challenge", value: challenge)])
    }

    func me() async throws -> MeResponse {
        let (data, _) = try await send("GET", "me")
        return try decode(MeResponse.self, from: data)
    }

    /// Membership-checked on the server, which also moves this device, so the
    /// next refresh stays in the org chosen here.
    func switchOrganization(to organizationId: String) async throws {
        _ = try await send("POST", "switch-org", body: ["organization_id": organizationId])
    }

    func notes(offset: Int = 0, limit: Int = 25) async throws -> NotePage {
        let (data, _) = try await send("GET", "notes", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ])
        return try decode(NotePage.self, from: data)
    }

    func note(id: String) async throws -> Note {
        let (data, _) = try await send("GET", "notes/\(id)")
        return try decode(DataEnvelope<Note>.self, from: data).data
    }

    /// Ends this device on the server with whichever token still works, then
    /// forgets both here. Local sign-out happens whatever the server says.
    func signOut() async {
        if let credentials = await tokens.current() {
            var request = URLRequest(url: url("auth/device/logout"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONEncoder.api.encode(["refresh_token": credentials.refreshToken])
            _ = try? await session.data(for: request)
        }
        await tokens.clear()
    }
}
