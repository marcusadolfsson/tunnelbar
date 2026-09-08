import ServiceManagement
import Testing
@testable import Tunnelbar

@Suite("Login item wording")
struct LoginItemTests {
    private func text(_ status: SMAppService.Status) -> String {
        LoginItem.explanation(for: status, bundlePath: "/Applications/Tunnelbar.app",
                              isBundled: true)
    }

    /// Regression. macOS reports `.notFound` before an app has ever been
    /// registered — not because the bundle is missing. Describing it as a
    /// lookup failure sent the reader to System Settings chasing a problem that
    /// did not exist, when registering from the toggle works normally.
    @Test func notFoundDoesNotClaimTheBundleIsMissing() {
        let message = text(.notFound)
        #expect(!message.lowercased().contains("could not find"))
        #expect(!message.contains("System Settings"))
        #expect(message == text(.notRegistered),
                "notFound and notRegistered are indistinguishable to the user")
    }

    /// The one state that genuinely needs the user to go somewhere.
    @Test func onlyRequiresApprovalPointsAtSystemSettings() {
        #expect(text(.requiresApproval).contains("System Settings"))
        #expect(!text(.enabled).contains("System Settings"))
    }

    /// Where macOS registered from matters: registration records the exact
    /// path, so moving the app afterwards silently breaks the login item.
    @Test func enabledStateNamesTheBundlePath() {
        #expect(text(.enabled).contains("/Applications/Tunnelbar.app"))
    }

    /// `SMAppService.mainApp` registers the running bundle, so running the
    /// binary straight out of SwiftPM has nothing meaningful to register.
    @Test func unbundledRunIsCalledOut() {
        let message = LoginItem.explanation(for: .notRegistered, bundlePath: "/x",
                                            isBundled: false)
        #expect(message.contains("Tunnelbar.app"))
    }
}

@Suite("Account ID handling")
struct AccountIDTests {
    /// A Cloudflare account id is 32 hex characters. Validating before saving
    /// stops a pasted URL fragment or tunnel id being stored as one.
    @Test(arguments: [
        "0123456789abcdef0123456789abcdef",
        "00000000000000000000000000000000",
        "ABCDEF0123456789abcdef0123456789",
    ])
    func acceptsWellFormedAccountIDs(_ value: String) {
        #expect(Preferences.isValidAccountID(value))
    }

    @Test(arguments: [
        "", "abc", "0123456789abcdef0123456789abcde",       // 31 chars
        "0123456789abcdef0123456789abcdefa",                 // 33 chars
        "11111111-1111-1111-1111-111111111111",              // a tunnel id
        "https://dash.cloudflare.com/0123456789abcdef01234567", // a pasted URL
    ])
    func rejectsMalformedAccountIDs(_ value: String) {
        #expect(!Preferences.isValidAccountID(value))
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(Preferences.isValidAccountID("  0123456789abcdef0123456789abcdef\n"))
    }
}
