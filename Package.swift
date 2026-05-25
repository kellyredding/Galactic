// swift-tools-version: 6.3
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
            exact: "1.13.0-galactic.4"
        )
    ],
    targets: [
        .target(
            name: "Galactic",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "GalacticTests",
            dependencies: ["Galactic"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
