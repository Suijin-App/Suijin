// swift-tools-version: 6.2
import PackageDescription

// SevindaTerminal — terminal engines (in-process PTY and the PTY host client), the SwiftTerm-based view, and the
// login-shell launch + shell integration (ZDOTDIR wrapper, bash rcfile, claude/codex account shell functions).
//
// SwiftTerm is pinned exactly: 1.20.0 is the newest 1.x release (Metal renderer). It compiles a Metal shader, so
// Xcode needs the Metal Toolchain component, and it ships the build-tool plugin `SwiftTermBuildInfoPlugin`, so
// `xcodebuild` needs `-skipPackagePluginValidation` (or a trusted plugin). 1.99.x are pre-2.0 builds with moving
// APIs. An upgrade must re-check the paste and key paths SevindaTerminalView overrides.
let package = Package(
    name: "SevindaTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SevindaTerminal", targets: ["SevindaTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(path: "../SevindaPTYProtocol"),
    ],
    targets: [
        // The PTY child side in C: between fork and exec only async-signal-safe calls may run, which Swift cannot
        // promise.
        .target(name: "CSevindaTerminalPTY"),
        .target(
            name: "SevindaTerminal",
            dependencies: [
                "CSevindaTerminalPTY",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SevindaPTYProtocol", package: "SevindaPTYProtocol"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "SevindaTerminalTests", dependencies: ["SevindaTerminal"]),
    ],
    swiftLanguageModes: [.v6]
)
