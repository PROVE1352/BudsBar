// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudsBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Protocol, transport and device model. No UI.
        .target(
            name: "BudsCore",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        // Menu bar app + debugging CLI (`BudsBar --cli ...`).
        .executableTarget(
            name: "BudsBar",
            dependencies: ["BudsCore"]
        ),
    ]
)
