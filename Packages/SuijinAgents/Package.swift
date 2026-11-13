// swift-tools-version: 6.2
import PackageDescription

// SuijinAgents — the agent catalog (claude, codex), launch specs, status tracking and Claude hooks.
let package = Package(
    name: "SuijinAgents",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinAgents", targets: ["SuijinAgents"])],
    dependencies: [.package(path: "../SuijinCore")],
    targets: [
        .target(name: "SuijinAgents", dependencies: ["SuijinCore"]),
        .testTarget(name: "SuijinAgentsTests", dependencies: ["SuijinAgents"]),
    ],
    swiftLanguageModes: [.v6]
)
