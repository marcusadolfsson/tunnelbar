import SwiftUI
import TunnelbarCore

/// Display rules for the model types. Kept apart from `TunnelbarCore` so the
/// discovery layer stays free of any UI framework.

extension Health {
    /// Status icons differ in *shape* as well as colour.
    ///
    /// Colour alone would be unreadable for a colourblind user and in a
    /// monochrome menu bar, and this glyph is the app's entire ambient signal.
    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .down: .red
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        case .unknown: "Unknown"
        }
    }
}

extension Ownership {
    /// Short badge text. Names the supervisor, because "who would restart this
    /// if I killed it" is the question the badge exists to answer.
    var badgeText: String {
        switch self {
        case .tunnelbar: "Tunnelbar"
        case .launchd: "launchd"
        case .homebrew: "brew services"
        case .shell: "shell"
        case .unknown: "external"
        }
    }

    var badgeSymbol: String {
        isManageable ? "app.badge.checkmark" : "lock.fill"
    }

    /// Explains why a row has no controls, for the row's help text.
    var readOnlyExplanation: String {
        switch self {
        case .tunnelbar:
            "Started by Tunnelbar."
        case .launchd:
            "Supervised by launchd. Stopping it here would fight its restart policy, "
            + "so Tunnelbar does not offer lifecycle controls."
        case .homebrew:
            "Supervised by brew services. Manage it with brew."
        case .shell:
            "Started from a shell. Manage it where it was started."
        case .unknown:
            "Tunnelbar could not identify what supervises this connector, so it "
            + "treats it as read-only."
        }
    }
}
