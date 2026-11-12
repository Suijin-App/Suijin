// swift-tools-version: 6.2
import PackageDescription

// MercuryAgents — the agent catalog (claude, codex), launch specs, status tracking and Claude hooks.
let package = Package(
    name: "MercuryAgents",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MercuryAgents", targets: ["MercuryAgents"])],
    dependencies: [.package(path: "../MercuryCore")],
    targets: [
        .target(name: "MercuryAgents", dependencies: ["MercuryCore"]),
        .testTarget(name: "MercuryAgentsTests", dependencies: ["MercuryAgents"]),
    ],
    swiftLanguageModes: [.v6]
)
