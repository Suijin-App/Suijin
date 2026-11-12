// swift-tools-version: 6.2
import PackageDescription

// MercuryUsage — reads Claude Code and Codex session logs (read-only) and aggregates token usage and estimated cost.
// No dependencies.
let package = Package(
    name: "MercuryUsage",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MercuryUsage", targets: ["MercuryUsage"])],
    targets: [
        .target(name: "MercuryUsage"),
        .testTarget(name: "MercuryUsageTests", dependencies: ["MercuryUsage"]),
    ],
    swiftLanguageModes: [.v6]
)
