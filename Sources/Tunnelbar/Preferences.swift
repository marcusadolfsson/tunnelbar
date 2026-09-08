import Foundation
import TunnelbarCore

/// Non-secret state that survives launches.
///
/// `UserDefaults` is right for exactly this and wrong for anything sensitive —
/// secrets live in `KeychainStore`. An account id and name are neither
/// credentials nor capabilities: knowing them grants nothing.
enum Preferences {
    private static let accountSummaryKey = "cloudflareAccountSummary"
    private static let accountIDsKey = "cloudflareAccountIDs"
    private static let manualAccountIDKey = "cloudflareManualAccountID"

    /// Which account the stored API token belongs to, so the settings panel can
    /// say more than "a token is stored".
    static var accountSummary: String? {
        get { UserDefaults.standard.string(forKey: accountSummaryKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountSummaryKey) }
    }

    /// Accounts the token could list, resolved at verification time.
    ///
    /// Usually **empty**, and that is not a failure. Cloudflare's account
    /// listing is authorization-aware: a token scoped only to Cloudflare
    /// Tunnel: Read gets 200 OK with zero accounts rather than a permission
    /// error. So this cannot be the only source of an account id.
    static var discoveredAccountIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: accountIDsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: accountIDsKey) }
    }

    /// Account id supplied by the user, or derived from a tunnel token.
    ///
    /// The reliable source. Asking for a broader token just to look up an id
    /// would mean requesting permissions no feature needs, which the project's token rules
    /// rules out.
    static var manualAccountID: String? {
        get { UserDefaults.standard.string(forKey: manualAccountIDKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(
                (trimmed?.isEmpty ?? true) ? nil : trimmed, forKey: manualAccountIDKey)
        }
    }

    /// Every account to query, discovered and manual, without duplicates.
    static var accountIDs: [String] {
        var ids = discoveredAccountIDs
        if let manual = manualAccountID, !ids.contains(manual) { ids.append(manual) }
        return ids
    }

    /// A Cloudflare account id is 32 hexadecimal characters.
    static func isValidAccountID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.count == 32 && trimmed.allSatisfy(\.isHexDigit)
    }

    static func clearAccountState() {
        UserDefaults.standard.removeObject(forKey: accountSummaryKey)
        UserDefaults.standard.removeObject(forKey: accountIDsKey)
        // The manual account id is deliberately kept: it is not derived from
        // the token, and retyping it after every token rotation is friction
        // with no security benefit.
    }
}
