import Foundation

/// The identifiers carried inside a tunnel token.
///
/// A tunnel token is base64-encoded JSON: `{"a": accountID, "t": tunnelID,
/// "s": secret}`. Parsing it locally means Tunnelbar can validate a pasted
/// token and derive the tunnel it belongs to without a network call and
/// without an API token.
public struct TunnelTokenIdentity: Sendable, Equatable {
    public let accountID: String
    public let tunnelID: String
}

public enum TunnelToken {
    /// Extracts the account and tunnel IDs from a token.
    ///
    /// Returns nil rather than throwing a descriptive error on purpose: an
    /// error message about a malformed token is a place a fragment of the token
    /// could end up in a log. The caller says "that token is not valid" and
    /// nothing more.
    public static func identity(of token: String) -> TunnelTokenIdentity? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tolerate a missing '=' pad, which is easy to lose when copying.
        var padded = trimmed
        if padded.count % 4 != 0 {
            padded += String(repeating: "=", count: 4 - padded.count % 4)
        }
        guard let data = Data(base64Encoded: padded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = object["a"] as? String,
              let tunnelID = object["t"] as? String,
              object["s"] is String,
              !accountID.isEmpty, !tunnelID.isEmpty
        else { return nil }

        return TunnelTokenIdentity(accountID: accountID, tunnelID: tunnelID)
    }

    /// Whether a string is a well-formed tunnel token. Used to validate input
    /// before it is written to the Keychain.
    public static func isValid(_ token: String) -> Bool { identity(of: token) != nil }
}
