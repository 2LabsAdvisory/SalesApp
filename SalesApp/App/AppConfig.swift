import Foundation

/// Where this build points, read from Info.plist.
///
/// The values are set per build configuration in the project — Debug talks to
/// the local Functions host, Release to production — so nothing here is chosen
/// at runtime or from anything a user can type.
enum AppConfig {
    static let apiBaseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SalesAPIBaseURL") as? String ?? ""
        guard let url = URL(string: raw), url.scheme != nil else {
            preconditionFailure("SalesAPIBaseURL is missing or malformed in Info.plist: \(raw)")
        }
        return url
    }()

    /// The custom scheme Microsoft sign-in returns on. It must match
    /// DEVICE_REDIRECT_URI on the Function App (salesby2labs://auth/microsoft).
    static let deviceRedirectScheme: String =
        Bundle.main.object(forInfoDictionaryKey: "SalesDeviceRedirectScheme") as? String ?? "salesby2labs"
}
