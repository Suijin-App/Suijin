// swift-tools-version: 6.2
import PackageDescription

// SuijinAccounts — managed Claude and Codex accounts: profile homes, login, identity, usage, launch env.
let package = Package(
    name: "SuijinAccounts",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinAccounts", targets: ["SuijinAccounts"])],
    dependencies: [.package(path: "../SuijinCore"), .package(path: "../SuijinAgents")],
    targets: [
        .target(name: "SuijinAccounts", dependencies: ["SuijinCore", "SuijinAgents"]),
        .testTarget(name: "SuijinAccountsTests", dependencies: ["SuijinAccounts"]),
    ],
    swiftLanguageModes: [.v6]
)
