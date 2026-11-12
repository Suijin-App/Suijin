// swift-tools-version: 6.2
import PackageDescription

// MercuryGit — the `git` CLI behind a typed API (worktrees, branches, diffs). No dependencies.
let package = Package(
    name: "MercuryGit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MercuryGit", targets: ["MercuryGit"])],
    targets: [
        .target(name: "MercuryGit"),
        .testTarget(name: "MercuryGitTests", dependencies: ["MercuryGit"]),
    ],
    swiftLanguageModes: [.v6]
)
