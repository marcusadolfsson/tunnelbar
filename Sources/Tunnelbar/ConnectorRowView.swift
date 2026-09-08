import AppKit
import SwiftUI
import TunnelbarCore

/// One connector in the dropdown.
///
/// The critical rule is expressed structurally here: the
/// lifecycle control group is inside `if connector.isManageable`, so for an
/// externally-owned connector those controls are *absent from the view tree*,
/// not rendered disabled. There is no styling path that could accidentally
/// re-enable them.
struct ConnectorRowView: View {
    let connector: Connector
    @Environment(ConnectorStore.self) private var store
    @State private var didCopy = false

    /// Present only for connectors Tunnelbar started.
    private var managed: ManagedConnector? { store.managed(for: connector.pid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            detail
            actions
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: connector.health.symbolName)
                .foregroundStyle(connector.health.tint)
                .accessibilityLabel(connector.health.label)

            Text(title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
            ownershipBadge
        }
    }

    /// Leads with the tunnel's friendly name when the Cloudflare API has been
    /// consulted, since that is what the user actually recognises. Without a
    /// token, falls back to the supervisor's label and finally the pid — a
    /// connector knows its own ID but not the name of the tunnel it serves.
    private var title: String {
        store.tunnelName(for: connector)
            ?? connector.ownerLabel
            ?? "cloudflared (pid \(connector.pid))"
    }

    private var ownershipBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: connector.ownership.badgeSymbol)
                .imageScale(.small)
            Text(connector.ownership.badgeText)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15), in: Capsule())
        .foregroundStyle(.secondary)
        .help(connector.ownership.readOnlyExplanation)
        .accessibilityLabel(
            connector.isManageable
                ? "Managed by Tunnelbar"
                : "Read-only, \(connector.ownership.badgeText)")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let metrics = connector.metrics {
                Text(Format.connections(ready: metrics.readyConnections))
                if !metrics.edgeConnections.isEmpty {
                    Text(Format.edgeLocations(metrics.edgeConnections))
                }
            } else if let error = connector.metricsError {
                // Surfaced rather than hidden: a connector whose metrics cannot
                // be read is still running, and saying so beats a blank row.
                Text(error).foregroundStyle(.orange)
            }

            // The descriptor repeats the title once a friendly name is known —
            // the tunnel name above, "tunnel <uuid>" below, saying the same thing
            // twice and putting a raw identifier in the most prominent list in
            // the app. Show it only when it still carries information: for a
            // quick tunnel, whose local target is not in the title, or when no
            // name could be resolved.
            if let managed, showsDescriptor(managed) {
                Text(managed.spec.descriptor)
                if let logPath = managed.instance?.logPath,
                   let hostname = ConnectorLauncher.quickTunnelHostname(logPath: logPath) {
                    Text(hostname).textSelection(.enabled)
                }
            }

            Text("up \(Format.uptime(connector.uptimeSeconds)) · pid \(connector.pid)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let connectorID = connector.metrics?.connectorID {
                Button(didCopy ? "Copied" : "Copy connector ID") {
                    copy(connectorID)
                }
                .disabled(didCopy)
            }

            // Lifecycle controls live here, and only for connectors Tunnelbar
            // started. Nothing is rendered for anything else — see the note at
            // the top of this file.
            if connector.isManageable, let instance = managed?.instance {
                Button("Stop") {
                    Task { await store.stop(pid: instance.pid) }
                }
            }

            Spacer()
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    /// Whether the spec descriptor adds anything the title has not said.
    private func showsDescriptor(_ managed: ManagedConnector) -> Bool {
        if case .quickTunnel = managed.spec { return true }
        return store.tunnelName(for: connector) == nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
