import Foundation
import TunnelbarCore

/// Headless discovery for Tunnelbar: prints connector state as JSON.
///
/// Exists as its own target so the risky half of the project — process,
/// socket, and ownership discovery — can be built and verified with no UI at
/// all. It is strictly read-only and takes no action against
/// any connector.

struct Options {
    var pretty = true
    var watchInterval: TimeInterval?
}

/// Argument-parsing failure. An empty message means `--help` was requested.
struct UsageError: Error {
    let message: String
}

func parseOptions(_ arguments: [String]) -> Result<Options, UsageError> {
    var options = Options()
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]
        switch argument {
        case "--compact":
            options.pretty = false
        case "--pretty":
            options.pretty = true
        case "--watch":
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, let seconds = Double(arguments[next]), seconds > 0 else {
                return .failure(UsageError(message: "--watch needs a positive number of seconds"))
            }
            options.watchInterval = seconds
            index = next
        case "-h", "--help":
            return .failure(UsageError(message: ""))
        default:
            return .failure(UsageError(message: "unknown argument: \(argument)"))
        }
        index = arguments.index(after: index)
    }
    return .success(options)
}

let usage = """
tunnelbar-discover — read-only discovery of cloudflared connectors

USAGE:
  tunnelbar-discover [--pretty|--compact] [--watch SECONDS]

OPTIONS:
  --pretty          Indented JSON (default)
  --compact         Single-line JSON, for piping into jq
  --watch SECONDS   Re-run on an interval, printing one report per cycle
  -h, --help        Show this help

This command only reads. It never starts, stops, or signals a connector.
"""

func makeEncoder(pretty: Bool) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

let options: Options
switch parseOptions(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed):
    options = parsed
case .failure(let error):
    if !error.message.isEmpty {
        FileHandle.standardError.write(Data("error: \(error.message)\n\n".utf8))
    }
    print(usage)
    exit(error.message.isEmpty ? 0 : 2)
}

let engine = DiscoveryEngine()
let encoder = makeEncoder(pretty: options.pretty)

func emit(_ report: DiscoveryReport) throws {
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
    // Flush per cycle so `--watch` stays usable through a pipe.
    fflush(stdout)
}

do {
    if let interval = options.watchInterval {
        while true {
            try emit(await engine.discover())
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    } else {
        let report = await engine.discover()
        try emit(report)
        // Exit code reflects the worst connector health, so shell callers can
        // branch without parsing JSON. An empty machine is 0, not a failure.
        exit(report.overallHealth == .down ? 1 : 0)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
