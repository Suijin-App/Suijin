// swift-tools-version: 6.2
import PackageDescription

// SevindaGit — the `git` CLI behind a typed API (worktrees, branches, diffs). No dependencies.
let package = Package(
    name: "SevindaGit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SevindaGit", targets: ["SevindaGit"])],
    targets: [
        .target(name: "SevindaGit"),
        .testTarget(name: "SevindaGitTests", dependencies: ["SevindaGit"]),
    ],
    swiftLanguageModes: [.v6]
)
