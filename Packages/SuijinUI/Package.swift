// swift-tools-version: 6.2
import PackageDescription

// SuijinUI — shared design system copied from CapstioUI; depends on no domain package.
let package = Package(
    name: "SuijinUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SuijinUI", targets: ["SuijinUI"])
    ],
    targets: [
        .target(name: "SuijinUI", resources: [.process("Resources")]),
        .testTarget(name: "SuijinUITests", dependencies: ["SuijinUI"]),
    ],
    swiftLanguageModes: [.v6]
)
