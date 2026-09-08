// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tunnelbar",
    // macOS 14: shareable with people not on macOS 26, and enough for both
    // MenuBarExtra (13+) and the Observation framework (14+).
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TunnelbarCore", targets: ["TunnelbarCore"]),
        .executable(name: "tunnelbar-discover", targets: ["tunnelbar-discover"]),
        .executable(name: "Tunnelbar", targets: ["Tunnelbar"]),
    ],
    targets: [
        .target(name: "TunnelbarCore"),
        .executableTarget(name: "tunnelbar-discover", dependencies: ["TunnelbarCore"]),
        // The menu bar app. Assembled into Tunnelbar.app by `make app`, since a
        // MenuBarExtra needs a bundle with LSUIElement to run as a status item.
        .executableTarget(name: "Tunnelbar", dependencies: ["TunnelbarCore"]),
        .testTarget(name: "TunnelbarCoreTests", dependencies: ["TunnelbarCore"]),
        .testTarget(name: "TunnelbarTests", dependencies: ["Tunnelbar", "TunnelbarCore"]),
    ]
)
