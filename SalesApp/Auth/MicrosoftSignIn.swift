import AuthenticationServices
import UIKit

/// Microsoft sign-in, in the system browser (FR15 §5.4).
///
/// `ASWebAuthenticationSession`, never an embedded web view: a web view the app
/// controls, showing someone else's identity provider, is indistinguishable
/// from a phishing screen, and Microsoft's conditional access and MFA expect
/// the real browser.
///
/// The round trip:
///   1. Make a PKCE pair here. The challenge goes to the API; the verifier
///      stays in this object.
///   2. Open `/api/auth/microsoft/start?device_challenge=…`. The API sends the
///      browser to Microsoft and handles the callback exactly as it does for
///      the web — every rule about who may sign in applies there.
///   3. The API redirects to `salesby2labs://auth/microsoft?code=…` (or
///      `?error=…`). The code is single-use and worthless without the verifier.
///   4. Redeem it at `/api/auth/device/exchange` with the verifier.
@MainActor
final class MicrosoftSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error, Equatable {
        case cancelled
        /// The API's own words — for example, not invited.
        case refused(String)
    }

    private var session: ASWebAuthenticationSession?

    func signIn(api: APIClient, device: DeviceDescription) async throws -> TokenBundle {
        let pkce = PKCE()
        let callback = try await authenticate(at: api.microsoftStartURL(challenge: pkce.challenge))

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let message = items.first(where: { $0.name == "error" })?.value {
            throw Failure.refused(message)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw Failure.refused("That sign-in didn't finish. Please try again.")
        }
        return try await api.exchangeMicrosoftCode(code, verifier: pkce.verifier, device: device)
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(AppConfig.deviceRedirectScheme),
                completionHandler: Self.completion(resuming: continuation))
            session.presentationContextProvider = self
            // No shared browser cookies: each sign-in is its own, and signing
            // out of Sales does not leave a Microsoft session behind in Safari.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: Failure.refused("Microsoft sign-in couldn't open. Try the email code instead."))
            }
        }
    }

    /// Built outside the main actor: the system may call it from any thread,
    /// and a closure written inside this class would trap there.
    nonisolated private static func completion(
        resuming continuation: CheckedContinuation<URL, Error>
    ) -> ASWebAuthenticationSession.CompletionHandler {
        { callbackURL, error in
            if let callbackURL {
                continuation.resume(returning: callbackURL)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: Failure.cancelled)
            } else {
                continuation.resume(throwing: Failure.refused("Microsoft sign-in couldn't open. Try the email code instead."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            // No key window yet: a fresh one on the first scene. There is always
            // a scene while the sign-in screen is showing.
            return ASPresentationAnchor(windowScene: scenes[0])
        }
    }
}
