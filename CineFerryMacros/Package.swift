// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "CineFerryMacros",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CineFerryMacros", targets: ["CineFerryMacros"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.1"),
    ],
    targets: [
        .macro(
            name: "CineFerryMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "CineFerryMacros", dependencies: ["CineFerryMacrosPlugin"]),
        .testTarget(
            name: "CineFerryMacrosTests",
            dependencies: [
                "CineFerryMacros",
                "CineFerryMacrosPlugin",
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
