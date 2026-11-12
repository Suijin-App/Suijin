// swift-tools-version: 6.2
import PackageDescription

// MercuryUI — shared design system copied from CapstioUI; depends on no domain package.
let package = Package(
    name: "MercuryUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MercuryUI", targets: ["MercuryUI"])
    ],
    targets: [
        .target(name: "MercuryUI", resources: [.process("Resources")]),
        .testTarget(name: "MercuryUITests", dependencies: ["MercuryUI"]),
    ],
    swiftLanguageModes: [.v6]
)
