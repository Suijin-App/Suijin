// swift-tools-version: 6.2
import PackageDescription

// MercuryPTYProtocol — the XPC contract between the app and the PTY host helper, plus MercuryPTYHostKit:
// the helper's session logic (PTY spawn, scrollback, session manager) as a library so it can be tested.
// CMercuryPTY is an internal C shim: the code between fork and exec must stay async-signal-safe, which Swift
// cannot guarantee. MercuryCLIKit is the `mercury` command's logic (parsing, broker transport), tested here and linked by
// the thin `Tools/MercuryCLI` executable.
let package = Package(
    name: "MercuryPTYProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MercuryPTYProtocol", targets: ["MercuryPTYProtocol"]),
        .library(name: "MercuryPTYHostKit", targets: ["MercuryPTYHostKit"]),
        .library(name: "MercuryCLIKit", targets: ["MercuryCLIKit"]),
    ],
    targets: [
        .target(name: "MercuryPTYProtocol"),
        .target(name: "CMercuryPTY"),
        .target(name: "MercuryPTYHostKit", dependencies: ["MercuryPTYProtocol", "CMercuryPTY"]),
        .target(name: "MercuryCLIKit", dependencies: ["MercuryPTYProtocol"]),
        .testTarget(name: "MercuryPTYProtocolTests", dependencies: ["MercuryPTYProtocol", "MercuryPTYHostKit", "MercuryCLIKit"]),
    ],
    swiftLanguageModes: [.v6]
)
