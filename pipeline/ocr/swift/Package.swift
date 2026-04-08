// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRAnalyzer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "guivision-ocr", targets: ["OCRAnalyzer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "OCRAnalyzer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
