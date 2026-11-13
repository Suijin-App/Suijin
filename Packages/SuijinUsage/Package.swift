// swift-tools-version: 6.2
import PackageDescription

// SuijinUsage — reads Claude Code and Codex session logs (read-only) and aggregates token usage and estimated cost.
// No dependencies.
let package = Package(
    name: "SuijinUsage",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinUsage", targets: ["SuijinUsage"])],
    targets: [
        .target(name: "SuijinUsage"),
        .testTarget(name: "SuijinUsageTests", dependencies: ["SuijinUsage"]),
    ],
    swiftLanguageModes: [.v6]
)
