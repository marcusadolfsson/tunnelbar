import Foundation
import Testing
@testable import TunnelbarCore

@Suite("Token template URL")
struct TokenTemplateTests {
    @Test func pointsAtTheDashboardTokenPage() {
        let url = TokenTemplate.creationURL()
        #expect(url.host == "dash.cloudflare.com")
        #expect(url.path == "/profile/api-tokens")
    }

    @Test func prefillsTheTokenName() {
        let items = URLComponents(url: TokenTemplate.creationURL(name: "My Token"),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "name" }?.value == "My Token")
    }

    /// Regression. `permissionGroupKeys` was carrying a guessed key that
    /// Cloudflare did not recognise, so the dashboard opened with an empty
    /// permission list and nothing to explain why. The keys are undocumented
    /// and cannot be looked up at runtime — the permission-groups API returns
    /// GUIDs and display names, not these keys — so the link must not pretend
    /// to preselect one.
    @Test func doesNotAttemptToPreselectAPermission() {
        let url = TokenTemplate.creationURL().absoluteString
        #expect(!url.contains("permissionGroupKeys"))
        #expect(!url.contains("argo_tunnel"))
    }

    /// The instruction that replaced the preselection has to name the exact
    /// dashboard path, or it is no better than nothing.
    @Test func statesTheRequiredPermission() {
        #expect(TokenTemplate.requiredPermission.contains("Cloudflare Tunnel"))
        #expect(TokenTemplate.requiredPermission.contains("Read"))
        #expect(TokenTemplate.requiredPermission.contains("Account"))
    }

    /// Read, never edit. The project rule is explicit.
    @Test func neverAsksForEdit() {
        #expect(!TokenTemplate.requiredPermission.lowercased().contains("edit"))
    }
}

@Suite("Cloudflare API errors")
struct CloudflareAPIErrorTests {
    /// The single most important property: an error string is the likeliest
    /// thing to reach a log or a bug report, so it must not be able to carry
    /// the token.
    @Test func errorsCarryNoToken() {
        let error = CloudflareAPIError("the token was rejected", codes: [1000])
        #expect(!error.description.lowercased().contains("bearer"))
        #expect(!error.description.contains("eyJ"))
        #expect(error.codes == [1000])
    }

    @Test func verificationStatusIsExplicit() {
        #expect(TokenVerification(id: "a", status: "active").isActive)
        #expect(!TokenVerification(id: "a", status: "disabled").isActive)
        #expect(!TokenVerification(id: "a", status: "expired").isActive)
    }
}
