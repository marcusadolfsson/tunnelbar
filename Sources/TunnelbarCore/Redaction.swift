import Foundation

/// Strips secrets out of process arguments before they reach any output.
///
/// This is not decoration. On this machine a live tunnel token is visible in
/// plain `ps` output as `--token eyJhIjoi...`, and a connector's argv is the
/// single most likely place for Tunnelbar to leak one into a log, a JSON dump,
/// or a bug report. Redaction happens at the point of capture (see
/// `ProcessScanner`), so no unredacted argv ever exists in a `Connector`.
public enum Redaction {
    /// Flags whose *following* argument is a secret.
    private static let secretFlagFragments = [
        "token", "secret", "password", "passwd", "apikey", "api-key",
        "credentials-contents", "cert-contents",
    ]

    public static let placeholder = "<redacted>"

    /// True if `flag` looks like it introduces a secret value.
    private static func isSecretFlag(_ flag: String) -> Bool {
        guard flag.hasPrefix("-") else { return false }
        let name = flag.drop(while: { $0 == "-" })
            .prefix(while: { $0 != "=" })
            .lowercased()
        return secretFlagFragments.contains { name.contains($0) }
    }

    /// True if a bare argument looks like a credential even without a flag.
    ///
    /// Tunnel tokens are long base64 blobs. A backstop for argument shapes we
    /// have not seen, at the cost of occasionally redacting a long opaque
    /// value that was not secret — the right trade in this direction.
    private static func looksLikeSecret(_ value: String) -> Bool {
        guard value.count >= 40, !value.hasPrefix("-"), !value.contains("/") else {
            return false
        }
        let base64ish = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-.")
        return value.unicodeScalars.allSatisfy(base64ish.contains)
    }

    /// Returns `arguments` with every secret value replaced by `placeholder`.
    public static func redact(arguments: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(arguments.count)
        var redactNext = false

        for argument in arguments {
            if redactNext {
                out.append(placeholder)
                redactNext = false
                continue
            }
            if isSecretFlag(argument) {
                // `--token=VALUE` carries the secret inline; `--token VALUE`
                // carries it in the next argument.
                if let equals = argument.firstIndex(of: "=") {
                    out.append("\(argument[..<equals])=\(placeholder)")
                } else {
                    out.append(argument)
                    redactNext = true
                }
                continue
            }
            out.append(looksLikeSecret(argument) ? placeholder : argument)
        }
        return out
    }
}
