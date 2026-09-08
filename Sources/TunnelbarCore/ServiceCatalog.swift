import Foundation

/// Best-effort identification of well-known listening services.
///
/// Most of what listens on a Mac is macOS itself, and a bare line like
/// `ControlCenter · all interfaces` reads as alarming when it is in fact
/// AirPlay Receiver doing exactly what it is meant to. Naming the common ones
/// turns an unreadable list into a list where anything *unnamed* is the part
/// worth a second look.
///
/// Matching is by process name, optionally narrowed by port. An unrecognised
/// service gets **no** description rather than a guess: a confident wrong label
/// on a security-adjacent list is worse than silence.
public enum ServiceCatalog {
    public struct Entry: Codable, Sendable, Equatable {
        /// One line, shown under the service.
        public let summary: String
        /// Whether this ships with macOS, as opposed to something installed.
        public let isSystem: Bool
        /// Anything genuinely worth knowing beyond the name.
        public let note: String?

        init(_ summary: String, isSystem: Bool = true, note: String? = nil) {
            self.summary = summary
            self.isSystem = isSystem
            self.note = note
        }
    }

    /// Entries keyed by process name *and* port, where the port disambiguates.
    private static let byNameAndPort: [String: [UInt16: Entry]] = [
        "controlcenter": [
            7000: Entry("AirPlay Receiver — control port"),
            5000: Entry("AirPlay Receiver",
                        note: "Commonly collides with dev servers on 5000. Turn it off in "
                            + "System Settings › General › AirDrop & Handoff."),
        ],
    ]

    /// Entries keyed by process name alone.
    private static let byName: [String: Entry] = [
        "rapportd": Entry("Continuity — Handoff, Universal Control, Sidecar, iPhone call relay"),
        "sharingd": Entry("AirDrop and macOS sharing services"),
        "airplayxpchelper": Entry("AirPlay support helper"),
        "screensharingd": Entry("Screen Sharing (VNC)"),
        "applevncserver": Entry("Screen Sharing (VNC)"),
        "smbd": Entry("File sharing over SMB"),
        "identityservicesd": Entry("iMessage and FaceTime"),
        "apsd": Entry("Apple Push Notification service"),
        "mdnsresponder": Entry("Bonjour service discovery"),
        "nsurlsessiond": Entry("Background downloads and uploads"),
        "remotepairingd": Entry("Developer device pairing"),
        "coredeviceservice": Entry("Xcode device services"),
        "cloudflared": Entry("Cloudflare Tunnel connector — the metrics endpoint Tunnelbar reads",
                             isSystem: false),
        "com.docker.backend": Entry("Docker Desktop", isSystem: false),
        "docker": Entry("Docker Desktop", isSystem: false),
        "ollama": Entry("Ollama — local model server", isSystem: false),
        "postgres": Entry("PostgreSQL", isSystem: false),
        "mysqld": Entry("MySQL", isSystem: false),
        "redis-server": Entry("Redis", isSystem: false),
        "mongod": Entry("MongoDB", isSystem: false),
    ]

    /// Ports distinctive enough to identify on their own, when the process name
    /// is not recognised.
    private static let byPort: [UInt16: Entry] = [
        5432: Entry("PostgreSQL", isSystem: false),
        3306: Entry("MySQL", isSystem: false),
        6379: Entry("Redis", isSystem: false),
        27017: Entry("MongoDB", isSystem: false),
        11434: Entry("Ollama — local model server", isSystem: false),
        5900: Entry("Screen Sharing (VNC)"),
        631: Entry("CUPS printing"),
    ]

    public static func describe(processName: String, port: UInt16) -> Entry? {
        let name = processName.lowercased()
        if let entry = byNameAndPort[name]?[port] { return entry }
        // A process with port-specific entries is only described on those
        // ports: ControlCenter listening somewhere unexpected is exactly the
        // case that should not be waved through as "AirPlay".
        if byNameAndPort[name] != nil { return nil }
        if let entry = byName[name] { return entry }
        return byPort[port]
    }
}
