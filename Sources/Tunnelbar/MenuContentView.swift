import SwiftUI
import TunnelbarCore

/// The dropdown shown from the status item.
struct MenuContentView: View {
    @Environment(ConnectorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var quickTunnelPort = "8080"
    @State private var isStarting = false
    @State private var servicesExpanded = false

    /// Resolves the account automatically, so no account ID is needed — and
    /// none is stored.
    private static let zeroTrustTunnelsURL =
        URL(string: "https://one.dash.cloudflare.com/?to=/:account/networks/tunnels")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.connectors.isEmpty && store.downManaged.isEmpty {
                emptyState
            } else {
                connectorList
            }
            downManagedSection
            tunnelsElsewhereSection
            localServicesSection
            Divider()
            quickTunnelControl
            Divider()
            footer
        }
        .frame(width: 340)
        // Refresh whenever the menu opens. Polling is a background heartbeat
        // tuned for battery, not for the moment someone actually looks — and
        // stale-on-open is the one time staleness is guaranteed to be noticed.
        .task { await store.refresh() }
    }

    /// Above this many connectors the list scrolls instead of growing a menu
    /// taller than the screen.
    private static let scrollThreshold = 4

    @ViewBuilder
    private var connectorList: some View {
        // A ScrollView has no intrinsic content height, and `maxHeight` is a
        // ceiling rather than a floor — so wrapping a short list in one inside
        // an unconstrained VStack collapses it to zero height and the rows
        // simply do not appear. Only scroll when there is actually too much to
        // fit, and give the ScrollView a floor when we do.
        if store.connectors.count > Self.scrollThreshold {
            ScrollView {
                connectorRows
            }
            .frame(minHeight: 240, maxHeight: 420)
        } else {
            connectorRows
        }
    }

    private var connectorRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.connectors.enumerated()), id: \.element.pid) { index, connector in
                if index > 0 { Divider().padding(.horizontal, 12) }
                ConnectorRowView(connector: connector)
            }
        }
    }

    /// Connectors Tunnelbar is supposed to be running that have no live
    /// process. Discovery cannot show these — there is no process to discover —
    /// so without this section a crashed connector would simply vanish from the
    /// menu, which is the opposite of what an observability app should do.
    @ViewBuilder
    private var downManagedSection: some View {
        if !store.downManaged.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.downManaged, id: \.id) { managed in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: RestartPolicy.isFailing(managed)
                                ? "exclamationmark.triangle.fill" : "arrow.clockwise")
                                .foregroundStyle(RestartPolicy.isFailing(managed) ? .red : .orange)
                            Text(managed.spec.descriptor)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Forget") { Task { await store.forget(managed) } }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        Text(statusText(for: managed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }

    /// Says what the supervisor is actually doing, rather than just "down".
    private func statusText(for managed: ManagedConnector) -> String {
        guard managed.autoRestart else {
            return "Stopped. Auto-restart is off for this connector."
        }
        let failures = managed.consecutiveFailures
        switch RestartPolicy.decide(for: managed, isLive: false, now: Date()) {
        case .restart:
            return "Down — restarting now."
        case .wait(let remaining):
            let seconds = max(1, Int(remaining.rounded()))
            return failures >= RestartPolicy.failingThreshold
                ? "Failing after \(failures) attempts — next retry in \(seconds)s."
                : "Down — retrying in \(seconds)s."
        case .idle:
            return "Down."
        }
    }

    /// Account tunnels with no connector on this Mac.
    ///
    /// The reason the API token exists. A tunnel that is down, or up but served
    /// from another machine, is invisible to local discovery — and is often
    /// exactly what someone opens this menu to check.
    @ViewBuilder
    private var tunnelsElsewhereSection: some View {
        let elsewhere = store.tunnelsElsewhere
        if !elsewhere.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Not running on this Mac")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ForEach(elsewhere) { tunnel in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: tunnel.status))
                            .foregroundStyle(tint(for: tunnel.status))
                            .imageScale(.small)
                        Text(tunnel.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(detail(for: tunnel))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        } else if let error = store.directoryError {
            Divider()
            Text("Account tunnels unavailable: \(error)")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    /// Local listening services, and which of them a tunnel publishes.
    ///
    /// Collapsed by default: on most Macs this is a long list of things nobody
    /// needs to think about, and the two facts worth surfacing — how many are
    /// reachable from the internet, and how many are bound to more than
    /// loopback — fit in the summary line.
    @ViewBuilder
    private var localServicesSection: some View {
        let exposures = store.exposures
        if !exposures.isEmpty {
            Divider()
            DisclosureGroup(isExpanded: $servicesExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(exposures) { exposure in
                        serviceRow(exposure)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(servicesSummary(exposures))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func servicesSummary(_ exposures: [ServiceExposure]) -> String {
        let exposed = exposures.filter(\.isExposed).count
        let wide = exposures.filter { !$0.service.isLoopbackOnly }.count
        var parts = ["\(exposures.count) local services"]
        if exposed > 0 { parts.append("\(exposed) published") }
        // Count only what the catalog could not name: the ordinary macOS
        // listeners are noise, and an unrecognised one is the thing worth
        // noticing.
        let unknown = exposures.filter { $0.service.catalog == nil }.count
        if unknown > 0 { parts.append("\(unknown) unrecognised") }
        _ = wide
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func serviceRow(_ exposure: ServiceExposure) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(":\(String(exposure.service.port))")
                    .font(.system(.caption, design: .monospaced))
                Text(exposure.service.processName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Bound beyond loopback is worth flagging on its own: it is
                // reachable from the local network with no tunnel involved.
                if !exposure.service.isLoopbackOnly {
                    Text("all interfaces")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            // Naming the ordinary ones is what makes an unnamed service stand
            // out, which is the whole point of showing this list.
            if let catalog = exposure.service.catalog {
                Text(catalog.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(exposure.bindings, id: \.hostname) { binding in
                Text("→ \(binding.hostname)  ·  \(binding.tunnelName)")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }
        }
    }

    private func symbol(for status: TunnelSummary.Status) -> String {
        switch status {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .inactive: "circle.dotted"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func tint(for status: TunnelSummary.Status) -> Color {
        switch status {
        case .healthy: .green
        case .degraded: .orange
        case .down: .red
        case .inactive, .unknown: .secondary
        }
    }

    /// A healthy tunnel running elsewhere is the interesting case, so say where
    /// rather than only that it is healthy.
    private func detail(for tunnel: TunnelSummary) -> String {
        guard tunnel.connectionCount > 0 else { return tunnel.status.label }
        let where_ = tunnel.colos.prefix(3).joined(separator: ", ")
        return where_.isEmpty
            ? "\(tunnel.status.label) · \(tunnel.connectionCount) connections"
            : "\(tunnel.status.label) · \(where_)"
    }

    /// No connectors running is a normal, correct state — not an error
    ///. It says what is true and what Tunnelbar will do next.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                Text("No connectors running").font(.body.weight(.medium))
            }
            Text("Tunnelbar will pick one up automatically when it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Quick tunnels are anonymous and ephemeral — no account, no token, no DNS
    /// record — so this is the one lifecycle action that is safe to offer with
    /// no configuration at all. The connector it creates is app-owned, and so
    /// is the only kind of row that gets a Stop button.
    private var quickTunnelControl: some View {
        HStack(spacing: 8) {
            Text("Quick tunnel").font(.caption).foregroundStyle(.secondary)
            TextField("port", text: $quickTunnelPort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .font(.caption)
            Button("Start") {
                guard let port = Int(quickTunnelPort), (1...65_535).contains(port) else { return }
                isStarting = true
                Task {
                    await store.startQuickTunnel(port: port)
                    isStarting = false
                }
            }
            .disabled(isStarting || Int(quickTunnelPort) == nil)
            .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.lastActionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.connectors.isEmpty {
                Text("Connectors Tunnelbar did not start are read-only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Button("Refresh") {
                    // Bypasses the account list's slow cadence: the user asked.
                    Task { await store.refreshEverything() }
                }
                .disabled(store.isRefreshing)

                Button("Settings") {
                    openWindow(id: TunnelbarApp.settingsWindowID)
                    // An LSUIElement app is not active by default, so the new
                    // window would open behind whatever the user is looking at.
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("Dashboard") {
                    NSWorkspace.shared.open(Self.zeroTrustTunnelsURL)
                }

                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(12)
        }
    }
}
