// swift-tools-version: 6.2
import PackageDescription

// SevindaUsage — reads Claude Code and Codex session logs (read-only) and aggregates token usage and estimated cost.
// No dependencies.
let package = Package(
    name: "SevindaUsage",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SevindaUsage", targets: ["SevindaUsage"])],
    targets: [
        .target(name: "SevindaUsage"),
        .testTarget(name: "SevindaUsageTests", dependencies: ["SevindaUsage"]),
    ],
    swiftLanguageModes: [.v6]
)
