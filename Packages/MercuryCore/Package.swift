// swift-tools-version: 6.2
import PackageDescription

// MercuryCore — models and persistent state (GRDB/SQLite). No UI dependency.
let package = Package(
    name: "MercuryCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MercuryCore", targets: ["MercuryCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0")],
    targets: [
        .target(name: "MercuryCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MercuryCoreTests", dependencies: ["MercuryCore"]),
    ],
    swiftLanguageModes: [.v6]
)
