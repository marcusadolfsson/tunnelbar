import Foundation
import Testing
@testable import TunnelbarCore

@Suite("Ingress rule parsing")
struct IngressRuleTests {
    private func rule(_ service: String, hostname: String? = "x.example.com") -> IngressRule {
        IngressRule(hostname: hostname, service: service)
    }

    @Test(arguments: [
        ("http://localhost:3000", UInt16(3000)),
        ("https://127.0.0.1:8443", UInt16(8443)),
        ("tcp://localhost:22", UInt16(22)),
        ("http://localhost:8080/path", UInt16(8080)),
    ])
    func readsTheLocalPort(_ service: String, _ expected: UInt16) {
        #expect(rule(service).localPort == expected)
    }

    /// Only http and https have a well-known default. Guessing one for any
    /// other scheme would invent an exposure that does not exist.
    @Test func usesWellKnownDefaultsOnlyWhereTheyExist() {
        #expect(rule("http://localhost").localPort == 80)
        #expect(rule("https://localhost").localPort == 443)
        #expect(rule("tcp://localhost").localPort == nil)
        #expect(rule("ssh://localhost").localPort == nil)
    }

    /// Catch-all rules end every ingress list and reach no local listener.
    /// Treating one as an exposure would mark a port published when it is not.
    @Test(arguments: ["http_status:404", "bastion", "hello_world"])
    func catchAllRulesExposeNothing(_ service: String) {
        #expect(rule(service, hostname: nil).localPort == nil)
        #expect(!rule(service, hostname: nil).targetsLocalhost)
    }

    /// A tunnel can route anywhere its connector reaches, so a rule pointing at
    /// another host must not claim a local port that shares its number.
    @Test func distinguishesLocalTargetsFromRemoteOnes() {
        #expect(rule("http://localhost:3000").targetsLocalhost)
        #expect(rule("http://127.0.0.1:3000").targetsLocalhost)
        #expect(!rule("http://192.168.1.50:3000").targetsLocalhost)
        #expect(!rule("http://backend.internal:3000").targetsLocalhost)
    }
}

@Suite("Service exposure join")
struct ExposureMapTests {
    private func service(_ port: UInt16, _ name: String = "node",
                         loopbackOnly: Bool = true) -> LocalService {
        LocalService(port: port, address: loopbackOnly ? "127.0.0.1" : "0.0.0.0",
                     pid: 1, processName: name, isLoopbackOnly: loopbackOnly)
    }

    /// The join that answers "what here is reachable from the internet".
    @Test func matchesAPublishedPortToItsHostname() {
        let map = ExposureMap(
            rulesByTunnel: ["t1": [
                IngressRule(hostname: "insta.example.com", service: "http://localhost:3000"),
                IngressRule(hostname: nil, service: "http_status:404"),
            ]],
            namesByTunnel: ["t1": "web-origin"])

        let exposures = map.exposures(for: [service(3000), service(5432, "postgres")])
        let published = exposures.first { $0.service.port == 3000 }
        #expect(published?.isExposed == true)
        #expect(published?.bindings.first?.hostname == "insta.example.com")
        #expect(published?.bindings.first?.tunnelName == "web-origin")

        #expect(exposures.first { $0.service.port == 5432 }?.isExposed == false)
    }

    /// A rule pointing at another machine must not mark a same-numbered local
    /// port as published — the false positive that matters here.
    @Test func doesNotClaimAPortRoutedToAnotherHost() {
        let map = ExposureMap(
            rulesByTunnel: ["t1": [
                IngressRule(hostname: "app.example.com", service: "http://10.0.0.5:3000"),
            ]],
            namesByTunnel: ["t1": "elsewhere"])
        #expect(map.exposures(for: [service(3000)]).first?.isExposed == false)
    }

    /// One port can be published on several hostnames, or by several tunnels.
    @Test func reportsEveryHostnameReachingAPort() {
        let map = ExposureMap(
            rulesByTunnel: [
                "t1": [IngressRule(hostname: "a.example.com", service: "http://localhost:3000")],
                "t2": [IngressRule(hostname: "b.example.com", service: "http://localhost:3000")],
            ],
            namesByTunnel: ["t1": "one", "t2": "two"])
        let bindings = map.exposures(for: [service(3000)]).first?.bindings ?? []
        #expect(bindings.map(\.hostname) == ["a.example.com", "b.example.com"])
    }

    /// Exposed services sort first: they are what the list exists to surface.
    @Test func sortsExposedServicesFirst() {
        let map = ExposureMap(
            rulesByTunnel: ["t1": [
                IngressRule(hostname: "a.example.com", service: "http://localhost:9000"),
            ]],
            namesByTunnel: ["t1": "one"])
        let ports = map.exposures(for: [service(80), service(9000)]).map(\.service.port)
        #expect(ports == [9000, 80])
    }

    /// With no token there are no rules, and nothing may be reported published.
    @Test func withoutIngressDataNothingIsClaimedExposed() {
        let map = ExposureMap(rulesByTunnel: [:], namesByTunnel: [:])
        #expect(map.exposures(for: [service(3000)]).allSatisfy { !$0.isExposed })
    }
}
