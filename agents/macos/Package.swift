// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GUIVisionAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "guivision-agent", targets: ["GUIVisionAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.21.0"),
    ],
    targets: [
        .target(
            name: "GUIVisionAgentProtocol",
            dependencies: [],
            path: "Sources/GUIVisionAgentProtocol"
        ),
        .target(
            name: "GUIVisionAgentLib",
            dependencies: [
                "GUIVisionAgentProtocol",
            ],
            path: "Sources/GUIVisionAgentLib",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "GUIVisionAgent",
            dependencies: [
                "GUIVisionAgentLib",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/GUIVisionAgent"
        ),
        .testTarget(
            name: "GUIVisionAgentTests",
            dependencies: [
                "GUIVisionAgentLib",
                "GUIVisionAgentProtocol",
            ],
            path: "Tests/GUIVisionAgentTests"
        ),
    ]
)
