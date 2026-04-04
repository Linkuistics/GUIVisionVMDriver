// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GUIVisionVMDriver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GUIVisionVMDriver", targets: ["GUIVisionVMDriver"]),
        .library(name: "GUIVisionAgentProtocol", targets: ["GUIVisionAgentProtocol"]),
        .executable(name: "guivision", targets: ["guivision"]),
        .executable(name: "guivision-agent", targets: ["guivision-agent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
        .executableTarget(
            name: "guivision-agent",
            dependencies: [
                "GUIVisionAgentProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/guivision-agent",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
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
        .testTarget(
            name: "GUIVisionAgentProtocolTests",
            dependencies: [
                "GUIVisionAgentProtocol",
            ],
            path: "Tests/GUIVisionAgentProtocolTests"
        ),
        .testTarget(
            name: "GUIVisionAgentTests",
            dependencies: [
                "GUIVisionAgentProtocol",
            ],
            path: "Tests/GUIVisionAgentTests"
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
