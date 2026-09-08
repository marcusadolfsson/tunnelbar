import SwiftUI
import TunnelbarCore

/// Token entry, backed by the Keychain.
///
/// A stored secret is never displayed, never read back into a field, and never
/// placed on the pasteboard. The UI shows only whether a secret *exists*, which
/// `KeychainStore.exists` answers without pulling the value into memory. Entry
/// fields are cleared the moment a value is written.
struct SettingsView: View {
    @Environment(ConnectorStore.self) private var store

    @State private var apiTokenInput = ""
    @State private var tunnelTokenInput = ""
    @State private var apiTokenStored = KeychainStore.exists(.cloudflareAPIToken)
    @State private var storedTunnelIDs: [String] = []
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isVerifying = false
    @State private var accountIDInput = Preferences.manualAccountID ?? ""
    @State private var message: Message?

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            startupSection
            Divider()
            apiTokenSection
            Divider()
            tunnelTokenSection
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: reload)
    }

    // MARK: - Startup

    /// Launch at login. Paired with the supervisor, this is what makes a
    /// Tunnelbar-owned connector survive a reboot — without it, a connector
    /// migrated away from launchd simply never comes back.
    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Startup").font(.headline)

            Toggle("Launch Tunnelbar at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }))
                .disabled(!LoginItem.isRunningFromBundle)

            Text(LoginItem.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !storedTunnelIDs.isEmpty {
                Text("Connectors Tunnelbar manages are restarted automatically when "
                     + "they exit. They only come back after a reboot if Tunnelbar "
                     + "itself launches at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cloudflare API token

    private var apiTokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloudflare API token").font(.headline)
            Text("Cloudflare has no sign-in flow that can issue a token to an app, "
                 + "so this opens the dashboard's token page with a name filled in. "
                 + "Choose **Create Custom Token**, add one permission, then paste "
                 + "the token back here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("Get API token…") {
                    NSWorkspace.shared.open(TokenTemplate.creationURL())
                }
                // Cloudflare does not publish the keys needed to preselect a
                // permission in the URL, and they cannot be looked up at
                // runtime either, so the instruction is spelled out instead.
                Text(TokenTemplate.requiredPermission)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                SecureField("Paste token", text: $apiTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { verifyAndSaveAPIToken() }
                Button(isVerifying ? "Checking…" : "Verify & Save") {
                    verifyAndSaveAPIToken()
                }
                .disabled(apiTokenInput.isEmpty || isVerifying)
            }

            accountIDField

            HStack(spacing: 8) {
                Image(systemName: apiTokenStored ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(apiTokenStored ? .green : .secondary)
                Text(apiTokenStored
                     ? (Preferences.accountSummary.map { "Verified · \($0)" } ?? "Stored in Keychain")
                     : "Not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if apiTokenStored {
                    Button("Remove") { removeAPIToken() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    /// Account id entry.
    ///
    /// Needed because a token scoped only to Cloudflare Tunnel: Read cannot
    /// list accounts — Cloudflare returns an empty list rather than an error,
    /// so there is nothing to discover and nothing that would look like a
    /// failure. Adding a tunnel token fills this in automatically, since the
    /// account id is encoded in the token itself.
    private var accountIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Account ID", text: $accountIDInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { saveAccountID() }
                Button("Save") { saveAccountID() }
                    .disabled(!Preferences.isValidAccountID(accountIDInput))
            }
            Text("Required for the account-wide tunnel list — a tunnel-scoped token "
                 + "cannot look this up. Find it in the dashboard URL, or add a "
                 + "tunnel token below and it fills in automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveAccountID() {
        guard Preferences.isValidAccountID(accountIDInput) else {
            message = Message(text: "An account ID is 32 hexadecimal characters.",
                              isError: true)
            return
        }
        Preferences.manualAccountID = accountIDInput.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        message = Message(text: "Account ID saved.", isError: false)
        Task { await store.refreshEverything() }
    }

    // MARK: - Tunnel tokens

    private var tunnelTokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tunnel tokens").font(.headline)
            Text("Each token lets Tunnelbar start a connector for one tunnel. "
                 + "The tunnel ID is read from the token itself, so there is nothing "
                 + "else to fill in.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                SecureField("Paste tunnel token", text: $tunnelTokenInput)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addTunnelToken() }
                    .disabled(tunnelTokenInput.isEmpty)
            }

            if storedTunnelIDs.isEmpty {
                Text("No tunnel tokens stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storedTunnelIDs, id: \.self) { tunnelID in
                    HStack {
                        Image(systemName: "key.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text(tunnelID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Start") {
                            Task { await store.startTunnel(tunnelID: tunnelID) }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        Button("Remove") { removeTunnelToken(tunnelID) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        apiTokenStored = KeychainStore.exists(.cloudflareAPIToken)
        storedTunnelIDs = (try? KeychainStore.storedTunnelIDs()) ?? []
        launchAtLogin = LoginItem.isEnabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            message = Message(
                text: enabled ? "Registered as a login item." : "Login item removed.",
                isError: false)
        } catch {
            message = Message(text: "Could not change the login item: \(error)", isError: true)
        }
        // Read the real status back rather than trusting the toggle: macOS may
        // land on `requiresApproval` instead of `enabled`.
        reload()
    }

    /// Verifies against the Cloudflare API *before* storing.
    ///
    /// A dead or mistyped token is never written to the Keychain, so
    /// "configured" in this panel always means "known to work" rather than
    /// "something was typed here once".
    private func verifyAndSaveAPIToken() {
        let token = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isVerifying = true
        message = nil

        Task {
            defer { isVerifying = false }
            let api = CloudflareAPI()
            do {
                let verification = try await api.verify(token: token)
                guard verification.isActive else {
                    message = Message(text: "That token is not active (status: "
                                      + "\(verification.status)).", isError: true)
                    return
                }

                // Best effort, and deliberately not fatal: naming the account
                // is a nicety, and a token scoped to tunnels only may not be
                // able to list accounts at all.
                let accounts = (try? await api.accounts(token: token)) ?? []
                let summary = accounts.count == 1
                    ? accounts[0].name
                    : accounts.map(\.name).joined(separator: ", ")

                try KeychainStore.set(token, for: .cloudflareAPIToken)
                Preferences.accountSummary = summary.isEmpty ? nil : summary

                Preferences.discoveredAccountIDs = accounts.map(\.id)

                // Clear immediately: the field has no reason to hold the value
                // once it is in the Keychain.
                apiTokenInput = ""
                // An empty account list is the normal result for a correctly
                // scoped token, so say what to do next rather than reporting a
                // bare success that leaves the tunnel list mysteriously empty.
                if summary.isEmpty && Preferences.accountIDs.isEmpty {
                    message = Message(
                        text: "Token verified and saved. Now add your Account ID above — "
                            + "a tunnel-scoped token cannot look it up.",
                        isError: false)
                } else {
                    message = Message(
                        text: summary.isEmpty
                            ? "Token verified and saved to Keychain."
                            : "Token verified for \(summary) and saved to Keychain.",
                        isError: false)
                }
            } catch {
                // Nothing is stored on failure.
                message = Message(text: "\(error)", isError: true)
            }
            reload()
        }
    }

    private func removeAPIToken() {
        do {
            try KeychainStore.delete(.cloudflareAPIToken)
            Preferences.clearAccountState()
            message = Message(text: "API token removed.", isError: false)
        } catch {
            message = Message(text: "\(error)", isError: true)
        }
        reload()
    }

    private func addTunnelToken() {
        // Parsed locally, so a malformed paste is caught before it is stored and
        // without a network call. The error deliberately says nothing about the
        // token's contents.
        guard let identity = TunnelToken.identity(of: tunnelTokenInput) else {
            message = Message(
                text: "That does not look like a tunnel token. Copy it from the "
                    + "Zero Trust dashboard, under the tunnel's install command.",
                isError: true)
            return
        }
        do {
            try KeychainStore.set(
                tunnelTokenInput.trimmingCharacters(in: .whitespacesAndNewlines),
                for: .tunnelToken(tunnelID: identity.tunnelID))
            tunnelTokenInput = ""
            // A tunnel token encodes its account id, so this is the one place
            // the account id arrives for free.
            var note = "Stored token for tunnel \(identity.tunnelID)."
            if Preferences.manualAccountID == nil {
                Preferences.manualAccountID = identity.accountID
                accountIDInput = identity.accountID
                note += " Account ID filled in from the token."
            }
            message = Message(text: note, isError: false)
        } catch {
            message = Message(text: "\(error)", isError: true)
        }
        reload()
    }

    private func removeTunnelToken(_ tunnelID: String) {
        do {
            try KeychainStore.delete(.tunnelToken(tunnelID: tunnelID))
            message = Message(text: "Removed token for \(tunnelID).", isError: false)
        } catch {
            message = Message(text: "\(error)", isError: true)
        }
        reload()
    }
}
