import Testing
@testable import TunnelbarCore

@Suite("Prometheus parsing")
struct PrometheusParserTests {
    /// Verbatim from the connector running on the development machine.
    static let liveSample = """
    # HELP cloudflared_tunnel_ha_connections Number of active ha connections
    # TYPE cloudflared_tunnel_ha_connections gauge
    cloudflared_tunnel_ha_connections 4
    cloudflared_tunnel_server_locations{connection_id="0",edge_location="mia09"} 1
    cloudflared_tunnel_server_locations{connection_id="1",edge_location="mia10"} 1
    cloudflared_tunnel_server_locations{connection_id="2",edge_location="mia01"} 1
    cloudflared_tunnel_server_locations{connection_id="3",edge_location="mia04"} 1
    cloudflared_tunnel_total_requests 640
    cloudflared_tunnel_concurrent_requests_per_tunnel 0
    """

    @Test func parsesLiveMetricsPayload() {
        let samples = PrometheusParser.parse(Self.liveSample)
        #expect(samples.count == 7)  // comments dropped
        #expect(samples.first { $0.name == "cloudflared_tunnel_ha_connections" }?.value == 4)
        #expect(samples.first { $0.name == "cloudflared_tunnel_total_requests" }?.value == 640)

        let locations = samples.filter { $0.name == "cloudflared_tunnel_server_locations" }
        #expect(locations.count == 4)
        #expect(Set(locations.compactMap { $0.labels["edge_location"] })
            == ["mia09", "mia10", "mia01", "mia04"])
    }

    @Test func ignoresCommentsAndBlankLines() {
        #expect(PrometheusParser.parse("# HELP x\n\n   \n# TYPE x gauge\n").isEmpty)
    }

    @Test func parsesUnlabelledSample() {
        let sample = PrometheusParser.parseLine("metric_name 12.5")
        #expect(sample?.name == "metric_name")
        #expect(sample?.value == 12.5)
        #expect(sample?.labels.isEmpty == true)
    }

    /// Prometheus permits a trailing timestamp; the value is still field one.
    @Test func ignoresTrailingTimestamp() {
        #expect(PrometheusParser.parseLine("metric 3 1699999999000")?.value == 3)
    }

    @Test(arguments: [("+Inf", Double.infinity), ("-Inf", -.infinity)])
    func parsesInfiniteValues(_ text: String, _ expected: Double) {
        #expect(PrometheusParser.parseLine("metric \(text)")?.value == expected)
    }

    @Test func parsesEscapedLabelValues() {
        let labels = PrometheusParser.parseLabels(#"path="a\"b",other="c""#)
        #expect(labels["path"] == #"a"b"#)
        #expect(labels["other"] == "c")
    }

    /// A `}` inside a quoted label value must not end the label set early.
    @Test func handlesBraceInsideLabelValue() {
        let sample = PrometheusParser.parseLine(#"metric{tag="a}b"} 7"#)
        #expect(sample?.labels["tag"] == "a}b")
        #expect(sample?.value == 7)
    }

    @Test func rejectsMalformedLines() {
        #expect(PrometheusParser.parseLine("just_a_name") == nil)
        #expect(PrometheusParser.parseLine("metric not_a_number") == nil)
    }
}
