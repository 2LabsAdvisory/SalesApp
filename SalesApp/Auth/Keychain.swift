import Foundation
import Security

/// The one place this app keeps a secret.
///
/// Every item is written `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (FR15 §3.3):
///
/// - **AfterFirstUnlock**, not `WhenUnlocked`, because "Hey Siri, take a 2Labs
///   note" must work with the phone locked (FR15 §8, decision 3), and sending
///   that note needs the token.
/// - **ThisDeviceOnly**, because a credential that rides a backup onto a second
///   phone is one you no longer control. Such items are never synced to iCloud
///   and are not restored to a different device.
///
/// Nothing sensitive goes in UserDefaults or a plist, anywhere in the app.
enum Keychain {
    enum Failure: Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "ca.2labs.sales"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.unexpectedStatus(status)
        }
    }

    static func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(baseQuery(account).merging(attributes) { $1 } as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.unexpectedStatus(added) }
        } else if status != errSecSuccess {
            throw Failure.unexpectedStatus(status)
        }
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }
}
