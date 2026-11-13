// swift-tools-version: 6.2
import PackageDescription

// SuijinTerminal — terminal engines (in-process PTY and the PTY host client), the SwiftTerm-based view, and the
// login-shell launch + shell integration (ZDOTDIR wrapper, bash rcfile, claude/codex account shell functions).
//
// SwiftTerm is pinned exactly: 1.20.0 is the newest 1.x release (Metal renderer). It compiles a Metal shader, so
// Xcode needs the Metal Toolchain component, and it ships the build-tool plugin `SwiftTermBuildInfoPlugin`, so
// `xcodebuild` needs `-skipPackagePluginValidation` (or a trusted plugin). 1.99.x are pre-2.0 builds with moving
// APIs. An upgrade must re-check the paste and key paths SuijinTerminalView overrides.
let package = Package(
    name: "SuijinTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SuijinTerminal", targets: ["SuijinTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(path: "../SuijinPTYProtocol"),
    ],
    targets: [
        // The PTY child side in C: between fork and exec only async-signal-safe calls may run, which Swift cannot
        // promise.
        .target(name: "CSuijinTerminalPTY"),
        .target(
            name: "SuijinTerminal",
            dependencies: [
                "CSuijinTerminalPTY",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SuijinPTYProtocol", package: "SuijinPTYProtocol"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "SuijinTerminalTests", dependencies: ["SuijinTerminal"]),
    ],
    swiftLanguageModes: [.v6]
)
