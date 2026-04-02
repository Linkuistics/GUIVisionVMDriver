// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GUIVisionVMDriver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GUIVisionVMDriver", targets: ["GUIVisionVMDriver"]),
        .executable(name: "guivision", targets: ["guivision"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(name: "royalvnc", path: "LocalPackages/royalvnc"),
    ],
    targets: [
        .target(
            name: "GUIVisionVMDriver",
            dependencies: [
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Sources/GUIVisionVMDriver",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "guivision",
            dependencies: [
                "GUIVisionVMDriver",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/guivision"
        ),
        // MARK: - Unit tests
        .testTarget(
            name: "GUIVisionVMDriverTests",
            dependencies: [
                "GUIVisionVMDriver",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/GUIVisionVMDriverTests"
        ),

        // MARK: - Integration tests (require a VNC endpoint)
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "GUIVisionVMDriver",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/IntegrationTests"
        ),
    ]
)
