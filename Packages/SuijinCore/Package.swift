// swift-tools-version: 6.2
import PackageDescription

// SuijinCore — models and persistent state (GRDB/SQLite). No UI dependency.
let package = Package(
    name: "SuijinCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinCore", targets: ["SuijinCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0")],
    targets: [
        .target(name: "SuijinCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SuijinCoreTests", dependencies: ["SuijinCore"]),
    ],
    swiftLanguageModes: [.v6]
)
