import Foundation

// What the API sends back, decoded with snake_case keys converted.

/// What a device sign-in and every refresh return (Sales-Functions
/// deviceStore.tokenResponse).
struct TokenBundle: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        let id: String
        let name: String
        let platform: String
    }

    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
    let device: Device
}

struct Organization: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
}

struct UserProfile: Decodable, Sendable {
    let id: String
    let email: String
    let firstName: String?
    let lastName: String?

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? email : full
    }
}

/// GET /api/me.
struct MeResponse: Decodable, Sendable {
    let user: UserProfile
    let organization: Organization
    let organizations: [Organization]
}

enum NoteSource: String, Codable, Sendable {
    case typed
    case siri
    case appRecorder = "app_recorder"
    case emailForward = "email_forward"

    var label: String {
        switch self {
        case .typed: "Typed"
        case .siri: "Siri"
        case .appRecorder: "In the app"
        case .emailForward: "Forwarded email"
        }
    }
}

enum NoteStatus: String, Decodable, Sendable {
    case needsLook = "needs_look"
    case needsAnswer = "needs_answer"
    case applied
    case logged
    case unfiled

    /// The two that mean somebody has to do something (FR06 §6.1).
    var needsAttention: Bool { self == .needsLook || self == .needsAnswer }
}

/// A note as the server holds it (FR06 §5).
struct Note: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let body: String
    let source: NoteSource
    let status: NoteStatus
    let outcome: String?
    let customerName: String?
    let contactName: String?
    let opportunityName: String?
    let createdAt: Date
    let capturedAt: Date?
    let clientId: String?

    /// When it was said, which for a queued note is earlier than when it arrived.
    var saidAt: Date { capturedAt ?? createdAt }
}

struct NotePage: Decodable, Sendable {
    let data: [Note]
    let total: Int
}

/// The `{ success, data }` shape most endpoints answer with.
struct DataEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T
}

/// Any error body the API sends: `{ success: false, error, code? }`.
struct ErrorBody: Decodable, Sendable {
    let error: String?
    let code: String?
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = APIDate.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date: \(raw)")
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(APIDate.format(date))
        }
        return encoder
    }()
}

/// ISO 8601, with or without fractional seconds — Postgres timestamps arrive
/// with them, and hand-written ones often do not.
enum APIDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parse(_ raw: String) -> Date? {
        (try? fractional.parse(raw)) ?? (try? whole.parse(raw))
    }

    static func format(_ date: Date) -> String {
        fractional.format(date)
    }
}
