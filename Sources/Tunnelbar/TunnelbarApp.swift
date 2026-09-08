import SwiftUI
import TunnelbarCore

/// Tunnelbar's menu bar entry point.
///
/// `LSUIElement` in the bundled Info.plist keeps it out of the Dock, so the
/// status item is the whole interface. The app never takes an action against a
/// connector — see `ConnectorRowView` and `TunnelbarCore.ReadOnlyCommand`.
@main
struct TunnelbarApp: App {
    @State private var store = ConnectorStore()

    /// Terminal commands, handled before any UI exists.
    ///
    /// A GUI app cannot report or fix its login-item state from a shell, and
    /// "why doesn't it start at login?" is otherwise unanswerable without
    /// clicking through System Settings. These also make the state scriptable,
    /// which matters because registration records the bundle path: reinstalling
    /// somewhere new means re-registering from the new location.
    init() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return }

        if let index = arguments.firstIndex(of: "--start-tunnel"),
           arguments.index(after: index) < arguments.endIndex {
            startTunnelFromCommandLine(tunnelID: arguments[arguments.index(after: index)])
        }
        if arguments.contains("--list-managed") {
            for entry in ConnectorRegistry.load() {
                let live = entry.instance.map(ConnectorRegistry.isLive) ?? false
                print("\(entry.spec.descriptor)")
                print("  pid \(entry.instance?.pid.description ?? "-")  live=\(live)  "
                      + "autoRestart=\(entry.autoRestart)  failures=\(entry.consecutiveFailures)")
            }
            if ConnectorRegistry.load().isEmpty { print("(nothing managed)") }
            exit(0)
        }
        if arguments.contains("--services") {
            runServiceReport()
        }
        if arguments.contains("--api-check") {
            // Answers "the token is stored, so why is the tunnel list empty?"
            // Each call is reported separately because they need different
            // permissions and fail independently.
            runAPICheck()
        }
        if arguments.contains("--token-url") {
            print("permission to select: \(TokenTemplate.requiredPermission)")
            print(TokenTemplate.creationURL().absoluteString)
            exit(0)
        }
        if arguments.contains("--login-item-status") {
            reportLoginItem()
            exit(0)
        }
        if arguments.contains("--enable-login-item") || arguments.contains("--disable-login-item") {
            let enable = arguments.contains("--enable-login-item")
            do {
                try LoginItem.setEnabled(enable)
                reportLoginItem()
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("error: could not \(enable ? "register" : "unregister"): \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// Exercises each API call the tunnel list depends on, printing what
    /// succeeded and what did not. Never prints the token.
    private func runAPICheck() {
        let semaphore = DispatchSemaphore(value: 0)
        // Detached, not `Task {}`. `App.init` is main-actor isolated, so a
        // plain Task inherits that isolation and can never run while the
        // semaphore below blocks the main thread — a deadlock, not a hang.
        Task.detached {
            defer { semaphore.signal() }
            guard let token = try? KeychainStore.read(.cloudflareAPIToken) else {
                print("no API token in the Keychain")
                return
            }
            print("token: stored (\(token.count) characters)")

            let api = CloudflareAPI()
            do {
                let verification = try await api.verify(token: token)
                print("verify: \(verification.status)")
            } catch {
                print("verify FAILED: \(error)")
            }

            do {
                let accounts = try await api.accounts(token: token)
                print("accounts: \(accounts.count) — \(accounts.map(\.name).joined(separator: ", "))")
                for account in accounts {
                    print("  id \(account.id)")
                }
            } catch {
                print("accounts FAILED: \(error)")
            }

            let known = Preferences.accountIDs
            print("remembered account ids: \(known.isEmpty ? "(none)" : known.joined(separator: ", "))")
            for accountID in known {
                do {
                    let tunnels = try await api.tunnels(accountID: accountID, token: token)
                    print("tunnels in \(accountID): \(tunnels.count)")
                    for tunnel in tunnels {
                        print("  \(tunnel.name) — \(tunnel.status.rawValue), "
                              + "\(tunnel.connectionCount) connections, "
                              + "connectorIDs \(tunnel.connectorIDs.count)")
                    }
                } catch {
                    print("tunnels in \(accountID) FAILED: \(error)")
                }
            }
        }
        semaphore.wait()
        exit(0)
    }

    /// Starts a managed connector for a tunnel whose token is in the Keychain.
    ///
    /// The connector outlives this short-lived process and is recorded in the
    /// registry, so the running menu bar app adopts and supervises it on its
    /// next poll. Ownership still resolves to Tunnelbar rather than launchd:
    /// the registry is consulted before parentage, which is exactly why it has
    /// to be.
    private func startTunnelFromCommandLine(tunnelID: String) {
        do {
            let managed = try ConnectorLauncher.start(.namedTunnel(tunnelID: tunnelID))
            let pid = managed.instance?.pid.description ?? "?"
            print("started pid \(pid) for \(managed.spec.descriptor)")
            print("log: \(managed.instance?.logPath ?? "-")")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Lists local listening services and which tunnel hostnames reach them.
    ///
    /// Neither half answers the question alone: the machine knows what is
    /// listening, and only Cloudflare knows what is published.
    private func runServiceReport() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            let services = ServiceScanner.listeningServices()

            var rules: [String: [IngressRule]] = [:]
            var names: [String: String] = [:]
            if let token = try? KeychainStore.read(.cloudflareAPIToken) {
                let api = CloudflareAPI()
                for accountID in Preferences.accountIDs {
                    guard let tunnels = try? await api.tunnels(accountID: accountID, token: token)
                    else { continue }
                    for tunnel in tunnels {
                        names[tunnel.id] = tunnel.name
                        if let ingress = try? await api.ingress(
                            accountID: accountID, tunnelID: tunnel.id, token: token) {
                            rules[tunnel.id] = ingress
                        }
                    }
                }
            } else {
                print("(no API token — local services only, no exposure information)")
            }

            let map = ExposureMap(rulesByTunnel: rules, namesByTunnel: names)
            for exposure in map.exposures(for: services) {
                let service = exposure.service
                let scope = service.isLoopbackOnly ? "loopback" : "all interfaces"
                print("\(service.port)  \(service.processName) (pid \(service.pid))  [\(scope)]")
                if let catalog = service.catalog {
                    print("     \(catalog.summary)")
                    if let note = catalog.note { print("     \(note)") }
                }
                if exposure.bindings.isEmpty {
                    print("     not exposed through any tunnel")
                } else {
                    for binding in exposure.bindings {
                        print("     → https://\(binding.hostname)  (tunnel \(binding.tunnelName))")
                    }
                }
            }
        }
        semaphore.wait()
        exit(0)
    }

    private func reportLoginItem() {
        print("bundle:  \(LoginItem.bundlePath)")
        print("status:  \(LoginItem.status.rawValue) — \(LoginItem.explanation)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
        } label: {
            // Nil health means discovery has not finished its first pass;
            // showing an indeterminate glyph avoids claiming "healthy" before
            // anything has actually been checked.
            Image(systemName: store.overallHealth?.symbolName ?? "circle.dotted")
                .accessibilityLabel(statusDescription)
                // The label is the one view that is always rendered, menu open
                // or closed, so it is where polling belongs: the status icon
                // must track health without the user opening anything.
                .task { store.start() }
        }
        // .window rather than .menu: rows carry multi-line detail and inline
        // buttons, which a standard menu cannot lay out.
        .menuBarExtraStyle(.window)

        Window("Tunnelbar Settings", id: TunnelbarApp.settingsWindowID) {
            SettingsView()
                .environment(store)
        }
        .windowResizability(.contentSize)
    }

    static let settingsWindowID = "settings"

    private var statusDescription: String {
        guard let health = store.overallHealth else { return "Tunnelbar, checking" }
        let count = store.connectors.count
        return count == 0
            ? "Tunnelbar, no connectors running"
            : "Tunnelbar, \(count) connector\(count == 1 ? "" : "s"), \(health.label)"
    }
}
