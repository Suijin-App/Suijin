// swift-tools-version: 6.2
import PackageDescription

// MercuryAccounts — managed Claude and Codex accounts: profile homes, login, identity, usage, launch env.
let package = Package(
    name: "MercuryAccounts",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MercuryAccounts", targets: ["MercuryAccounts"])],
    dependencies: [.package(path: "../MercuryCore"), .package(path: "../MercuryAgents")],
    targets: [
        .target(name: "MercuryAccounts", dependencies: ["MercuryCore", "MercuryAgents"]),
        .testTarget(name: "MercuryAccountsTests", dependencies: ["MercuryAccounts"]),
    ],
    swiftLanguageModes: [.v6]
)
