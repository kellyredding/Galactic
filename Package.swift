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
            exact: "1.13.0-galactic.11"
        )
    ],
    targets: [
        .target(
            name: "Galactic",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            // Emoji autocomplete data and behaviour, injected into card
            // composers. Copied rather than processed: these ship to a WebView
            // verbatim, and processing would let the toolchain rewrite the
            // exact bytes the page is meant to evaluate.
            resources: [
                .copy("Resources/emoji-data.js"),
                .copy("Resources/emoji-autocomplete.js"),
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
