// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gatekeeper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Gatekeeper", targets: ["Gatekeeper"]),
               .executable(name: "SmokeCheck", targets: ["SmokeCheck"])],
    targets: [
        .target(name: "GatekeeperCore"),
        .executableTarget(name: "Gatekeeper", dependencies: ["GatekeeperCore"]),
        .executableTarget(name: "SmokeCheck", dependencies: ["GatekeeperCore"]),
        .testTarget(name: "GatekeeperTests", dependencies: ["Gatekeeper", "GatekeeperCore"])
    ],
    swiftLanguageModes: [.v5]
)
