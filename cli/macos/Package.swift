// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GUIVisionVMDriver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GUIVisionVMDriver", targets: ["GUIVisionVMDriver"]),
        .library(name: "GUIVisionAgentProtocol", targets: ["GUIVisionAgentProtocol"]),
        .executable(name: "guivision", targets: ["guivision"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.21.0"),
        .package(name: "royalvnc", path: "LocalPackages/royalvnc"),
    ],
    targets: [
        // MARK: - Libraries
        .target(
            name: "GUIVisionAgentProtocol",
            dependencies: [],
            path: "Sources/GUIVisionAgentProtocol"
        ),
        .target(
            name: "GUIVisionVMDriver",
            dependencies: [
                "GUIVisionAgentProtocol",
                .product(name: "Hummingbird", package: "hummingbird"),
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

        // MARK: - Executables
        .executableTarget(
            name: "guivision",
            dependencies: [
                "GUIVisionAgentProtocol",
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
                "GUIVisionAgentProtocol",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/GUIVisionVMDriverTests"
        ),
        .testTarget(
            name: "GUIVisionAgentProtocolTests",
            dependencies: [
                "GUIVisionAgentProtocol",
            ],
            path: "Tests/GUIVisionAgentProtocolTests"
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
