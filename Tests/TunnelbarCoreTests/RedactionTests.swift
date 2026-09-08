import Testing
@testable import TunnelbarCore

@Suite("Redaction")
struct RedactionTests {
    /// The argv shape of a launchd-supervised connector, with a synthetic
    /// token standing in for the real one. A live tunnel token is visible in
    /// plain `ps` output on a machine running one, so this is the case that
    /// must never regress — and the fixture itself must never carry a real
    /// account identifier.
    @Test func redactsSpaceSeparatedToken() {
        let argv = ["/opt/homebrew/bin/cloudflared", "--no-autoupdate", "tunnel", "run",
                    "--token", "eyJhIjoiMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAiLCJ0IjoiMTExMTExMTEtMTExMS0xMTExLTExMTEtMTExMTExMTExMTExIiwicyI6ImMzbHVkR2hsZEdsaiJ9"]
        let redacted = Redaction.redact(arguments: argv)
        #expect(redacted == ["/opt/homebrew/bin/cloudflared", "--no-autoupdate",
                             "tunnel", "run", "--token", "<redacted>"])
    }

    @Test func redactsInlineToken() {
        let redacted = Redaction.redact(arguments: ["tunnel", "run", "--token=abc123secret"])
        #expect(redacted == ["tunnel", "run", "--token=<redacted>"])
    }

    @Test(arguments: ["--token", "-token", "--api-key", "--password", "--credentials-contents"])
    func redactsEverySecretFlag(_ flag: String) {
        #expect(Redaction.redact(arguments: [flag, "value"]) == [flag, "<redacted>"])
    }

    /// Backstop for argv shapes not yet seen: a long base64 blob is treated as
    /// a credential even with no flag introducing it.
    @Test func redactsBareTokenShapedArgument() {
        let blob = String(repeating: "A", count: 48)
        #expect(Redaction.redact(arguments: ["tunnel", "run", blob]) == ["tunnel", "run", "<redacted>"])
    }

    /// Redaction must not eat the information the UI actually needs.
    @Test func keepsOrdinaryArguments() {
        let argv = ["cloudflared", "tunnel", "run", "--metrics", "127.0.0.1:20241", "my-tunnel"]
        #expect(Redaction.redact(arguments: argv) == argv)
    }

    /// A long path is not a secret, and hiding it would obscure which binary
    /// is running.
    @Test func keepsLongPaths() {
        let path = "/opt/homebrew/Cellar/cloudflared/2026.8.3/bin/cloudflared"
        #expect(Redaction.redact(arguments: [path]) == [path])
    }
}
