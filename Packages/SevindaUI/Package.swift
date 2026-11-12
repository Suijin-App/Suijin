// swift-tools-version: 6.2
import PackageDescription

// SevindaUI — shared design system copied from CapstioUI; depends on no domain package.
let package = Package(
    name: "SevindaUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SevindaUI", targets: ["SevindaUI"])
    ],
    targets: [
        .target(name: "SevindaUI", resources: [.process("Resources")]),
        .testTarget(name: "SevindaUITests", dependencies: ["SevindaUI"]),
    ],
    swiftLanguageModes: [.v6]
)
