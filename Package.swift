// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Galactic",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Galactic",
            targets: ["Galactic"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/kellyredding/SwiftTerm.git",
            exact: "1.13.0-galactic.12"
        ),
        // Markdown parsing for the reader subsystem. One parse feeds every
        // emitter — see Sources/Galactic/Markdown.
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            from: "0.5.0"
        )
    ],
    targets: [
        .target(
            name: "Galactic",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            // Emoji autocomplete data and behaviour, injected into card
            // composers, plus the vendored highlighting and diagram assets a
            // reader document splices in. Copied rather than processed: these
            // ship to a WebView verbatim, and processing would let the
            // toolchain rewrite the exact bytes the page is meant to evaluate.
            resources: [
                .copy("Resources/emoji-data.js"),
                .copy("Resources/emoji-autocomplete.js"),
                .copy("Resources/highlight.min.js"),
                .copy("Resources/github.min.css"),
                .copy("Resources/github-dark.min.css"),
                .copy("Resources/mermaid.min.js"),
            ]
        ),
        .testTarget(
            name: "GalacticTests",
            dependencies: ["Galactic"],
            // The fixture both matchers are checked against. Copied rather
            // than processed: it is read as bytes and parsed as JSON, and
            // processing would let the toolchain rewrite what the two sides
            // are supposed to agree on.
            resources: [.copy("Fixtures/text-entry-cases.json")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
