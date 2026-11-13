// swift-tools-version: 6.2
import PackageDescription

// SuijinDiff — native read-only unified diff viewer (TextKit 2) with tree-sitter syntax highlighting.
// Grammar versions are pinned exactly: grammar repos regenerate parser.c between releases and a silent
// bump can change the ABI or the capture names our highlight mapping relies on.
let package = Package(
    name: "SuijinDiff",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinDiff", targets: ["SuijinDiff"])],
    dependencies: [
        .package(path: "../SuijinGit"),
        .package(path: "../SuijinUI"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
    ],
    targets: [
        // tree-sitter-javascript and tree-sitter-python decide whether to compile `src/scanner.c` with
        // `FileManager.fileExists` relative to the manifest's working directory, which SwiftPM does not set
        // to the package root, so their external scanners are silently left out and linking fails. This
        // target compiles the unmodified scanners copied from the same pinned tags. Delete it once upstream
        // lists the scanner unconditionally (as tree-sitter-typescript and tree-sitter-rust do).
        .target(name: "TreeSitterScanners"),
        .target(
            name: "SuijinDiff",
            dependencies: [
                "TreeSitterScanners",
                "SuijinGit",
                "SuijinUI",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SuijinDiffTests", dependencies: ["SuijinDiff"]),
    ],
    swiftLanguageModes: [.v6]
)
