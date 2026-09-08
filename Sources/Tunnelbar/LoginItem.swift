import Foundation
import ServiceManagement

/// Launch at login, via `SMAppService`.
///
/// Together with `ConnectorSupervisor` this is what completes the replacement
/// for a launchd `KeepAlive` agent: the supervisor brings a connector back when
/// it dies, and this brings Tunnelbar itself back after a reboot. Without both,
/// a Tunnelbar-owned connector is simply gone after a restart.
enum LoginItem {
    /// `SMAppService.mainApp` registers *the running bundle*, so it is
    /// meaningless when the binary was run directly by SwiftPM rather than from
    /// `Tunnelbar.app`.
    static var isRunningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Where macOS would register from. Surfaced in the UI because
    /// registration records this exact path: moving the app afterwards leaves a
    /// login item pointing at nothing, and that failure is otherwise silent.
    static var bundlePath: String {
        Bundle.main.bundleURL.path
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Human-readable state, including the case where macOS has the request but
    /// is waiting on the user.
    static var explanation: String {
        explanation(for: status, bundlePath: bundlePath, isBundled: isRunningFromBundle)
    }

    /// Pure so the wording can be tested without touching system state — this
    /// mapping has already been wrong once.
    static func explanation(
        for status: SMAppService.Status, bundlePath: String, isBundled: Bool
    ) -> String {
        guard isBundled else {
            return "Only available when running from Tunnelbar.app."
        }
        switch status {
        case .enabled:
            return "Tunnelbar will start at login, from \(bundlePath)."
        case .notRegistered:
            return "Tunnelbar will not start at login."
        case .requiresApproval:
            return "Approval needed — enable Tunnelbar in System Settings › "
                + "General › Login Items."
        case .notFound:
            // Not the failure the name suggests. macOS reports `.notFound`
            // when it simply has no record of this app yet — the state before
            // a first registration, indistinguishable in practice from
            // `.notRegistered`. Registering from here works normally; reading
            // it as "broken bundle" sends people to System Settings chasing a
            // problem that does not exist.
            return "Tunnelbar will not start at login."
        @unknown default:
            return "Unknown login item state."
        }
    }
}
