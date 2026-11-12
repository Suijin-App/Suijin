// swift-tools-version: 6.2
import PackageDescription

// SevindaAccounts — managed Claude and Codex accounts: profile homes, login, identity, usage, launch env.
let package = Package(
    name: "SevindaAccounts",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SevindaAccounts", targets: ["SevindaAccounts"])],
    dependencies: [.package(path: "../SevindaCore"), .package(path: "../SevindaAgents")],
    targets: [
        .target(name: "SevindaAccounts", dependencies: ["SevindaCore", "SevindaAgents"]),
        .testTarget(name: "SevindaAccountsTests", dependencies: ["SevindaAccounts"]),
    ],
    swiftLanguageModes: [.v6]
)
