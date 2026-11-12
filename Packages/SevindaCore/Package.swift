// swift-tools-version: 6.2
import PackageDescription

// SevindaCore — models and persistent state (GRDB/SQLite). No UI dependency.
let package = Package(
    name: "SevindaCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SevindaCore", targets: ["SevindaCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0")],
    targets: [
        .target(name: "SevindaCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SevindaCoreTests", dependencies: ["SevindaCore"]),
    ],
    swiftLanguageModes: [.v6]
)
