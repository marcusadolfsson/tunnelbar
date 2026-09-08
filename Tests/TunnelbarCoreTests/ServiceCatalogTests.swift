import Testing
@testable import TunnelbarCore

@Suite("Service catalog")
struct ServiceCatalogTests {
    /// The two that appear on nearly every Mac and read as alarming without
    /// context: ControlCenter bound to all interfaces is AirPlay Receiver.
    @Test func namesAirPlayReceiverOnBothItsPorts() {
        #expect(ServiceCatalog.describe(processName: "ControlCenter", port: 7000)?
            .summary.contains("AirPlay") == true)
        #expect(ServiceCatalog.describe(processName: "ControlCenter", port: 5000)?
            .summary.contains("AirPlay") == true)
    }

    /// The 5000 collision is the single most useful thing to say about it.
    @Test func flagsTheWellKnownPort5000Collision() {
        let note = ServiceCatalog.describe(processName: "ControlCenter", port: 5000)?.note
        #expect(note?.contains("5000") == true)
        #expect(ServiceCatalog.describe(processName: "ControlCenter", port: 7000)?.note == nil)
    }

    /// A port-qualified process seen on an *unexpected* port must not inherit
    /// the label. ControlCenter listening somewhere new is precisely what
    /// should not be waved through as "AirPlay, nothing to see".
    @Test func doesNotExtendAPortSpecificLabelToOtherPorts() {
        #expect(ServiceCatalog.describe(processName: "ControlCenter", port: 9999) == nil)
    }

    @Test func namesContinuity() {
        let entry = ServiceCatalog.describe(processName: "rapportd", port: 49154)
        #expect(entry?.summary.contains("Continuity") == true)
        #expect(entry?.isSystem == true)
    }

    /// Distinguishing macOS from installed software is the difference between
    /// "expected" and "you chose to run this".
    @Test func separatesSystemServicesFromInstalledOnes() {
        #expect(ServiceCatalog.describe(processName: "rapportd", port: 49154)?.isSystem == true)
        #expect(ServiceCatalog.describe(processName: "cloudflared", port: 20241)?.isSystem == false)
        #expect(ServiceCatalog.describe(processName: "postgres", port: 5432)?.isSystem == false)
    }

    /// Falls back to a distinctive port when the process name is unfamiliar.
    @Test func identifiesDistinctivePortsWithoutTheProcessName() {
        #expect(ServiceCatalog.describe(processName: "some-wrapper", port: 5432)?
            .summary.contains("PostgreSQL") == true)
    }

    /// Silence, not a guess. A confident wrong label on a security-adjacent
    /// list is worse than none, and an unnamed service is the signal to look.
    @Test func returnsNothingForUnknownServices() {
        #expect(ServiceCatalog.describe(processName: "node", port: 3000) == nil)
        #expect(ServiceCatalog.describe(processName: "my-app", port: 41234) == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(ServiceCatalog.describe(processName: "controlcenter", port: 7000) != nil)
        #expect(ServiceCatalog.describe(processName: "RAPPORTD", port: 1) != nil)
    }
}
