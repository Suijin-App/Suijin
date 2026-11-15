// swift-tools-version: 6.2
import PackageDescription

// SuijinMarkdown — the live-rendered Markdown editor: a tree-sitter syntax tree over the Markdown source, the style
// runs and hideable markers derived from it, and the AppKit text view that shows them. Imports no domain package.
// The grammar is pinned to the same version as in SuijinDiff, which highlights Markdown in diffs with it.
let package = Package(
    name: "SuijinMarkdown",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SuijinMarkdown", targets: ["SuijinMarkdown"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
    ],
    targets: [
        .target(
            name: "SuijinMarkdown",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ]
        ),
        .testTarget(name: "SuijinMarkdownTests", dependencies: ["SuijinMarkdown"]),
    ],
    swiftLanguageModes: [.v6]
)
