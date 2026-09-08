import Foundation
import Testing
@testable import TunnelbarCore

@Suite("Tunnel token parsing")
struct TunnelTokenTests {
    /// Shape only — synthetic ids, no real account or tunnel.
    static func makeToken(account: String = "00000000000000000000000000000000",
                          tunnel: String = "11111111-1111-1111-1111-111111111111",
                          secret: String = "c3ludGhldGlj") -> String {
        let json = #"{"a":"\#(account)","t":"\#(tunnel)","s":"\#(secret)"}"#
        return Data(json.utf8).base64EncodedString()
    }

    @Test func extractsAccountAndTunnelIDs() {
        let identity = TunnelToken.identity(of: Self.makeToken())
        #expect(identity?.accountID == "00000000000000000000000000000000")
        #expect(identity?.tunnelID == "11111111-1111-1111-1111-111111111111")
    }

    /// Base64 padding is easy to lose when copying a token out of a terminal.
    @Test func toleratesMissingPadding() {
        let token = Self.makeToken()
        let unpadded = token.replacingOccurrences(of: "=", with: "")
        #expect(TunnelToken.identity(of: unpadded)?.tunnelID
            == TunnelToken.identity(of: token)?.tunnelID)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(TunnelToken.isValid("  \n\(Self.makeToken())\n  "))
    }

    @Test(arguments: [
        "", "   ", "not-base64-at-all!!", "eyJmb28iOiJiYXIifQ==",  // valid base64, wrong shape
    ])
    func rejectsMalformedTokens(_ token: String) {
        #expect(!TunnelToken.isValid(token))
    }

    /// A token missing any of the three fields is not usable.
    @Test func requiresAllThreeFields() {
        let missingSecret = Data(#"{"a":"acc","t":"tun"}"#.utf8).base64EncodedString()
        #expect(!TunnelToken.isValid(missingSecret))
        let emptyTunnel = Data(#"{"a":"acc","t":"","s":"x"}"#.utf8).base64EncodedString()
        #expect(!TunnelToken.isValid(emptyTunnel))
    }
}

@Suite("Keychain item shape")
struct KeychainStoreTests {
    /// Account names must be distinct and stable: a collision between the API
    /// token and a tunnel token would overwrite one with the other.
    @Test func secretsHaveDistinctAccounts() {
        let api = KeychainStore.Secret.cloudflareAPIToken.account
        let one = KeychainStore.Secret.tunnelToken(tunnelID: "abc").account
        let two = KeychainStore.Secret.tunnelToken(tunnelID: "def").account
        #expect(Set([api, one, two]).count == 3)
        #expect(one.hasPrefix(KeychainStore.tunnelTokenPrefix))
        #expect(!api.hasPrefix(KeychainStore.tunnelTokenPrefix))
    }

    /// Round-trips the account name, so `storedTunnelIDs` can recover the id.
    @Test func tunnelIDRoundTripsThroughAccountName() {
        let tunnelID = "11111111-1111-1111-1111-111111111111"
        let account = KeychainStore.Secret.tunnelToken(tunnelID: tunnelID).account
        #expect(String(account.dropFirst(KeychainStore.tunnelTokenPrefix.count)) == tunnelID)
    }

    /// The single most important property of the error type: an error string is
    /// the likeliest thing to reach a log or a bug report, so it must not be
    /// able to carry the secret.
    @Test func errorsNeverCarryTheSecret() {
        let error = KeychainStore.KeychainError(operation: "read", status: errSecItemNotFound)
        let text = error.description
        #expect(text.contains("read"))
        #expect(!text.contains("eyJ"))
        #expect(text.count < 200)
    }

    /// A fresh install has neither secret, and that is not an error condition.
    @Test func absentSecretReadsAsNilNotAsFailure() throws {
        let unusedTunnel = KeychainStore.Secret.tunnelToken(
            tunnelID: "tunnelbar-test-absent-\(UUID().uuidString)")
        #expect(!KeychainStore.exists(unusedTunnel))
        #expect(try KeychainStore.read(unusedTunnel) == nil)
    }
}

/// Exercises the real Keychain. Off by default, since it writes to the login
/// keychain. Run with `TUNNELBAR_INTEGRATION=1 swift test`.
@Suite("Keychain round trip", .enabled(if: ProcessInfo.processInfo.environment["TUNNELBAR_INTEGRATION"] != nil))
struct KeychainIntegrationTests {
    @Test func writesReadsListsAndDeletes() throws {
        let tunnelID = "tunnelbar-selftest-\(UUID().uuidString)"
        let secret = KeychainStore.Secret.tunnelToken(tunnelID: tunnelID)
        let token = TunnelTokenTests.makeToken(tunnel: tunnelID)
        defer { try? KeychainStore.delete(secret) }

        #expect(!KeychainStore.exists(secret))
        try KeychainStore.set(token, for: secret)
        #expect(KeychainStore.exists(secret))
        #expect(try KeychainStore.read(secret) == token)
        #expect(try KeychainStore.storedTunnelIDs().contains(tunnelID))

        // Overwrite must update in place, not create a duplicate item.
        let rotated = TunnelTokenTests.makeToken(tunnel: tunnelID, secret: "cm90YXRlZA==")
        try KeychainStore.set(rotated, for: secret)
        #expect(try KeychainStore.read(secret) == rotated)
        #expect(try KeychainStore.storedTunnelIDs().filter { $0 == tunnelID }.count == 1)

        try KeychainStore.delete(secret)
        #expect(!KeychainStore.exists(secret))
        #expect(try KeychainStore.read(secret) == nil)
        // Deleting something already gone is a no-op, not a failure.
        #expect(throws: Never.self) { try KeychainStore.delete(secret) }
    }
}
