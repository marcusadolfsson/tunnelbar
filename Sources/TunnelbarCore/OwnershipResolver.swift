import Darwin
import Foundation

/// Determines who supervises each discovered connector.
///
/// Getting this wrong in the permissive direction is the worst bug Tunnelbar
/// could ship: mislabelling a launchd-supervised connector as app-owned would
/// put a stop button in front of a `KeepAlive` agent. Every code path here
/// therefore fails closed — anything not positively identified as app-owned
/// stays read-only.
public struct OwnershipResolver: Sendable {
    /// pids this app started and still tracks. Empty until v0.3 adds lifecycle
    /// controls; the plumbing exists now so ownership has one honest source.
    private let appOwnedPIDs: Set<pid_t>
    private let launchdPIDs: [pid_t: String]
    private let homebrewPIDs: Set<pid_t>
    public let notes: [DiscoveryNote]

    public init() {
        var notes: [DiscoveryNote] = []
        self.appOwnedPIDs = Self.loadAppOwnedPIDs()
        self.launchdPIDs = Self.launchdSupervisedPIDs(notes: &notes)
        self.homebrewPIDs = Self.homebrewSupervisedPIDs(notes: &notes)
        // Docker Desktop runs containers inside a VM, so a containerised
        // connector never appears in this machine's process table at all. It is
        // therefore not a case this resolver can mislabel — it is a case
        // discovery cannot see. Out of scope for v0.1.
        self.notes = notes
    }

    /// Resolves ownership for one process, most specific claim first.
    public func ownership(for process: RunningProcess) -> (Ownership, String?) {
        if appOwnedPIDs.contains(process.pid) {
            return (.tunnelbar, "Tunnelbar")
        }
        if let label = launchdPIDs[process.pid] {
            return (.launchd, label)
        }
        if homebrewPIDs.contains(process.pid) {
            return (.homebrew, "brew services")
        }
        // Reparented to launchd without a matching label: a daemonised process
        // whose supervisor we could not name. Not ours, so not manageable.
        if process.parentPID == 1 {
            return (.unknown, nil)
        }
        if let parentPath = ProcessScanner.executablePath(of: process.parentPID) {
            return (.shell, (parentPath as NSString).lastPathComponent)
        }
        return (.unknown, nil)
    }

    // MARK: - App-owned registry

    static var appOwnedRegistryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tunnelbar/owned.json")
    }

    /// Reads the app-owned registry, honouring only entries that still pass
    /// `ConnectorRegistry`'s pid-reuse validation. A missing file means "we own
    /// nothing", which is a correct and common state.
    private static func loadAppOwnedPIDs() -> Set<pid_t> {
        Set(ConnectorRegistry.liveInstances().map { $0.instance.pid })
    }

    // MARK: - launchd

    /// launchd jobs whose program arguments mention `cloudflared`, mapped to
    /// their current pid.
    ///
    /// The plist is read as data. Where a job's command line contains a shell
    /// expression, that expression is matched as text and never executed or
    /// resolved — on this machine one such job interpolates a token file, and
    /// reading that file is forbidden by the project's hard constraints.
    private static func launchdSupervisedPIDs(notes: inout [DiscoveryNote]) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let domains: [(URL, String)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "gui/\(getuid())"),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "gui/\(getuid())"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "system"),
        ]

        for (directory, domain) in domains {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []

            for url in entries where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any],
                      let label = plist["Label"] as? String
                else { continue }

                var commandLine: [String] = []
                if let program = plist["Program"] as? String { commandLine.append(program) }
                if let arguments = plist["ProgramArguments"] as? [String] {
                    commandLine.append(contentsOf: arguments)
                }
                guard commandLine.joined(separator: " ").contains("cloudflared") else { continue }

                if let pid = launchdPID(domain: domain, label: label) {
                    result[pid] = label
                } else {
                    notes.append(DiscoveryNote(
                        kind: "launchd",
                        detail: "job \(label) references cloudflared but reported no running pid"
                    ))
                }
            }
        }
        return result
    }

    /// Current pid of a launchd job, via `launchctl print` — a read-only verb.
    private static func launchdPID(domain: String, label: String) -> pid_t? {
        // `try?` flattens the optional returned by `run`, so an absent binary
        // and a rejected command are indistinguishable here — both mean
        // "no pid", which is the safe answer either way.
        guard let output = try? ReadOnlyCommand.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        else { return nil }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return pid_t(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - Homebrew

    /// pids of connectors supervised by `brew services`.
    ///
    /// On this machine `brew services list` reports `cloudflared none`, meaning
    /// brew is deliberately not supervising it. This only ever
    /// reads that list.
    private static func homebrewSupervisedPIDs(notes: inout [DiscoveryNote]) -> Set<pid_t> {
        // `brew` is frequently absent from a non-interactive PATH, so probe the
        // standard prefixes rather than trusting the environment.
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return [] }

        guard let output = try? ReadOnlyCommand.run(brew, ["services", "list", "--json"]),
              let data = output.data(using: .utf8),
              let services = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            notes.append(DiscoveryNote(
                kind: "homebrew", detail: "brew found at \(brew) but its service list could not be read"))
            return []
        }

        var pids = Set<pid_t>()
        for service in services where (service["name"] as? String) == "cloudflared" {
            if let pid = service["pid"] as? Int, pid > 0 {
                pids.insert(pid_t(pid))
            }
        }
        return pids
    }
}
