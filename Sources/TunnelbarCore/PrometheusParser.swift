import Foundation

/// One sample line from a Prometheus text exposition.
public struct PrometheusSample: Sendable, Equatable {
    public let name: String
    public let labels: [String: String]
    public let value: Double
}

/// A minimal parser for the Prometheus text format.
///
/// Hand-rolled on purpose: Tunnelbar needs a handful of
/// `cloudflared_tunnel_*` lines with simple string labels, which is not worth a
/// dependency. It handles comments, labelled and unlabelled samples, escaped
/// label values, and the `NaN`/`+Inf` value forms; it does not attempt
/// histograms, summaries, or exemplars, none of which cloudflared's metrics
/// require here.
public enum PrometheusParser {
    public static func parse(_ text: String) -> [PrometheusSample] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            parseLine(String(line))
        }
    }

    static func parseLine(_ rawLine: String) -> PrometheusSample? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        let name: String
        let labels: [String: String]
        let remainder: Substring

        if let braceStart = line.firstIndex(of: "{") {
            guard let braceEnd = closingBrace(in: line, from: braceStart) else { return nil }
            name = String(line[..<braceStart])
            labels = parseLabels(String(line[line.index(after: braceStart)..<braceEnd]))
            remainder = line[line.index(after: braceEnd)...]
        } else {
            guard let space = line.firstIndex(of: " ") else { return nil }
            name = String(line[..<space])
            labels = [:]
            remainder = line[space...]
        }

        // A sample may carry a trailing timestamp; the value is the first field.
        let fields = remainder.split(separator: " ", omittingEmptySubsequences: true)
        guard !name.isEmpty, let first = fields.first, let value = parseValue(String(first))
        else { return nil }

        return PrometheusSample(name: name, labels: labels, value: value)
    }

    /// The `}` that closes the label set, ignoring braces inside quoted values.
    private static func closingBrace(in line: String, from start: String.Index) -> String.Index? {
        var index = line.index(after: start)
        var inQuotes = false
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "}" && !inQuotes {
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func parseValue(_ text: String) -> Double? {
        switch text {
        case "+Inf": .infinity
        case "-Inf": -.infinity
        case "NaN": .nan
        default: Double(text)
        }
    }

    /// Splits `connection_id="0",edge_location="mia09"` into a dictionary.
    static func parseLabels(_ body: String) -> [String: String] {
        var labels: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var escaped = false
        var readingValue = false

        func commit() {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { labels[trimmed] = value }
            key = ""
            value = ""
            readingValue = false
        }

        for character in body {
            if escaped {
                // Prometheus escapes only \\, \" and \n inside label values.
                value.append(character == "n" ? "\n" : character)
                escaped = false
            } else if inQuotes && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if inQuotes {
                value.append(character)
            } else if character == "=" {
                readingValue = true
            } else if character == "," {
                commit()
            } else if !readingValue {
                key.append(character)
            }
        }
        commit()
        return labels
    }
}
