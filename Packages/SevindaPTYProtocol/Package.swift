// swift-tools-version: 6.2
import PackageDescription

// SevindaPTYProtocol — the XPC contract between the app and the PTY host helper, plus SevindaPTYHostKit:
// the helper's session logic (PTY spawn, scrollback, session manager) as a library so it can be tested.
// CSevindaPTY is an internal C shim: the code between fork and exec must stay async-signal-safe, which Swift
// cannot guarantee. SevindaCLIKit is the `sevinda` command's logic (parsing, broker transport), tested here and linked by
// the thin `Tools/SevindaCLI` executable.
let package = Package(
    name: "SevindaPTYProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SevindaPTYProtocol", targets: ["SevindaPTYProtocol"]),
        .library(name: "SevindaPTYHostKit", targets: ["SevindaPTYHostKit"]),
        .library(name: "SevindaCLIKit", targets: ["SevindaCLIKit"]),
    ],
    targets: [
        .target(name: "SevindaPTYProtocol"),
        .target(name: "CSevindaPTY"),
        .target(name: "SevindaPTYHostKit", dependencies: ["SevindaPTYProtocol", "CSevindaPTY"]),
        .target(name: "SevindaCLIKit", dependencies: ["SevindaPTYProtocol"]),
        .testTarget(name: "SevindaPTYProtocolTests", dependencies: ["SevindaPTYProtocol", "SevindaPTYHostKit", "SevindaCLIKit"]),
    ],
    swiftLanguageModes: [.v6]
)
