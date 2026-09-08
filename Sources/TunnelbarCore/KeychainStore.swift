import Foundation
import Security

/// Secret storage, backed by the macOS Keychain.
///
/// Two kinds of secret live here and nothing else:
///
/// - the Cloudflare API token, one per install, for reading account-wide tunnel
///   state, and
/// - tunnel tokens, one per tunnel Tunnelbar owns, each of which can start a
///   connector for that tunnel.
///
/// Account IDs, tunnel IDs, names, and connector IDs are **not** secrets and are
/// not stored here. Nothing is ever written to a plist, a dotfile, or
/// `UserDefaults`.
public enum KeychainStore {
    /// Matches the bundle identifier so items are attributable in Keychain Access.
    public static let service = "com.adolfsson.tunnelbar"
    static let tunnelTokenPrefix = "tunnel-token:"

    public enum Secret: Sendable, Equatable {
        case cloudflareAPIToken
        case tunnelToken(tunnelID: String)

        var account: String {
            switch self {
            case .cloudflareAPIToken: "cloudflare-api-token"
            case .tunnelToken(let tunnelID): "\(KeychainStore.tunnelTokenPrefix)\(tunnelID)"
            }
        }

        var label: String {
            switch self {
            case .cloudflareAPIToken: "Tunnelbar — Cloudflare API token"
            case .tunnelToken(let tunnelID): "Tunnelbar — tunnel \(tunnelID)"
            }
        }
    }

    /// A Keychain failure.
    ///
    /// Carries the operation and `OSStatus` only. It must never carry the
    /// secret or any part of it: an error string is precisely the value most
    /// likely to reach a log or a bug report.
    public struct KeychainError: Error, CustomStringConvertible {
        public let operation: String
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "keychain \(operation) failed: \(message ?? "OSStatus \(status)")"
        }
    }

    /// Base query identifying one item.
    ///
    /// `ThisDeviceOnly` keeps these out of iCloud Keychain. A tunnel token that
    /// synced to the user's other Macs would let any of them start a connector
    /// for that tunnel — duplicate edge connections for one tunnel, arriving
    /// from a machine the user was not thinking about.
    private static func query(for secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.account,
        ]
    }

    public static func set(_ value: String, for secret: Secret) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError(operation: "encode", status: errSecParam)
        }

        let existing = SecItemCopyMatching(query(for: secret) as CFDictionary, nil)
        if existing == errSecSuccess {
            let status = SecItemUpdate(
                query(for: secret) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError(operation: "update", status: status)
            }
            return
        }

        var attributes = query(for: secret)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = secret.label
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(operation: "add", status: status)
        }
    }

    /// Reads a secret. Returns nil when absent, which is an ordinary state, not
    /// an error — a fresh install has neither secret.
    public static func read(_ secret: Secret) throws -> String? {
        var attributes = query(for: secret)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a secret exists, without reading it.
    ///
    /// Lets the UI show "configured" without triggering a Keychain access
    /// prompt or pulling the value into memory for no reason.
    public static func exists(_ secret: Secret) -> Bool {
        SecItemCopyMatching(query(for: secret) as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ secret: Secret) throws {
        let status = SecItemDelete(query(for: secret) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    /// Tunnel IDs that have a stored token. Reads attributes only, never values.
    public static func storedTunnelIDs() throws -> [String] {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let entries = items as? [[String: Any]] else {
            throw KeychainError(operation: "list", status: status)
        }
        return entries
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(tunnelTokenPrefix) }
            .map { String($0.dropFirst(tunnelTokenPrefix.count)) }
            .sorted()
    }
}
