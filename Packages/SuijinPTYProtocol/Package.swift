// swift-tools-version: 6.2
import PackageDescription

// SuijinPTYProtocol — the XPC contract between the app and the PTY host helper, plus SuijinPTYHostKit:
// the helper's session logic (PTY spawn, scrollback, session manager) as a library so it can be tested.
// CSuijinPTY is an internal C shim: the code between fork and exec must stay async-signal-safe, which Swift
// cannot guarantee. SuijinCLIKit is the `suijin` command's logic (parsing, broker transport), tested here and linked by
// the thin `Tools/SuijinCLI` executable.
let package = Package(
    name: "SuijinPTYProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SuijinPTYProtocol", targets: ["SuijinPTYProtocol"]),
        .library(name: "SuijinPTYHostKit", targets: ["SuijinPTYHostKit"]),
        .library(name: "SuijinCLIKit", targets: ["SuijinCLIKit"]),
    ],
    targets: [
        .target(name: "SuijinPTYProtocol"),
        .target(name: "CSuijinPTY"),
        .target(name: "SuijinPTYHostKit", dependencies: ["SuijinPTYProtocol", "CSuijinPTY"]),
        .target(name: "SuijinCLIKit", dependencies: ["SuijinPTYProtocol"]),
        .testTarget(name: "SuijinPTYProtocolTests", dependencies: ["SuijinPTYProtocol", "SuijinPTYHostKit", "SuijinCLIKit"]),
    ],
    swiftLanguageModes: [.v6]
)
