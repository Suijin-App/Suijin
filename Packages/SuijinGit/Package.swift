// swift-tools-version: 6.2
import PackageDescription

// SuijinGit — the `git` CLI behind a typed API (worktrees, branches, diffs). No dependencies.
let package = Package(
    name: "SuijinGit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinGit", targets: ["SuijinGit"])],
    targets: [
        .target(name: "SuijinGit"),
        .testTarget(name: "SuijinGitTests", dependencies: ["SuijinGit"]),
    ],
    swiftLanguageModes: [.v6]
)
