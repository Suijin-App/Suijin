// swift-tools-version: 6.2
import PackageDescription

// SevindaAgents — the agent catalog (claude, codex), launch specs, status tracking and Claude hooks.
let package = Package(
    name: "SevindaAgents",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SevindaAgents", targets: ["SevindaAgents"])],
    dependencies: [.package(path: "../SevindaCore")],
    targets: [
        .target(name: "SevindaAgents", dependencies: ["SevindaCore"]),
        .testTarget(name: "SevindaAgentsTests", dependencies: ["SevindaAgents"]),
    ],
    swiftLanguageModes: [.v6]
)
