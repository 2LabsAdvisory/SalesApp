import CryptoKit
import Foundation

/// The phone's own PKCE pair for the Microsoft handoff (RFC 7636, S256).
///
/// The challenge goes to the API when sign-in starts; the verifier stays in
/// memory on this phone and is sent only when redeeming the handoff code. A
/// code lifted from the redirect by another app is useless without it.
struct PKCE: Sendable {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 48)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure randomness available")
        self.init(verifier: Data(bytes).base64URLEncoded)
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
