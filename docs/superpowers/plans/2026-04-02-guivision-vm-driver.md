# GUIVisionVMDriver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract VNC driver, input handling, SSH client, streaming capture, and CLI from TestAnyware/TestAnywareRedux into a focused, well-tested Swift library and CLI tool.

**Architecture:** A Swift Package with a library target (`GUIVisionVMDriver`) and CLI target (`guivision`). The library wraps RoyalVNCKit for VNC connection/capture/input, provides platform-aware keysym mapping, manages SSH connections via ControlMaster for persistent sessions, supports streaming framebuffer capture to video, and exposes cursor tracking. The CLI exposes all library functionality via swift-argument-parser subcommands.

**Tech Stack:** Swift 6.0, RoyalVNCKit (vendored), swift-argument-parser, macOS 14+, AVFoundation (streaming capture), CoreGraphics, Vision framework (not for AI — just CGImage/pixel ops)

---

## Source Projects

Code is extracted primarily from **TestAnywareRedux** (`../TestAnywareRedux/core/Sources/Core/`) with select enhancements from **TestAnyware** (`../TestAnyware/Sources/TestAnywareLib/`). The key differences:

| Feature | TestAnywareRedux | TestAnyware | GUIVisionVMDriver |
|---|---|---|---|
| Platform-aware modifiers | ✅ PlatformKeymap | ❌ hardcoded macOS | ✅ from Redux |
| Raw keysym bypass (ARD) | ❌ | ✅ useRawKeysyms | ✅ from TestAnyware |
| Shifted char handling | ❌ basic | ✅ shiftedCharToBase | ✅ from TestAnyware |
| VNCSpec-based init | ✅ | ❌ raw params | ✅ from Redux |
| Cursor tracking | ❌ ignored | ❌ ignored | ✅ new |
| SSH client | ❌ empty dir | ❌ shells out ad-hoc | ✅ new (ControlMaster) |
| Streaming capture | ❌ | ❌ | ✅ new (AVAssetWriter) |
| CLI | ✅ ArgumentParser | ❌ ad-hoc main.swift | ✅ from Redux pattern |

## File Structure

```
GUIVisionVMDriver/
├── Package.swift
├── README.md
├── LICENSE
├── LocalPackages/
│   └── royalvnc/                          # Vendored RoyalVNCKit fork (copied from TestAnywareRedux)
├── Sources/
│   ├── GUIVisionVMDriver/                 # Library target
│   │   ├── Connection/
│   │   │   ├── ConnectionSpec.swift       # VNCSpec, SSHSpec, ConnectionSpec, parsing
│   │   │   └── Platform.swift             # Platform enum (macos/windows/linux)
│   │   ├── VNC/
│   │   │   ├── VNCCapture.swift           # Actor: connect, disconnect, capture, screenSize
│   │   │   ├── VNCCaptureDelegate.swift   # RoyalVNCKit delegate bridge
│   │   │   ├── VNCCaptureError.swift      # Error enum
│   │   │   ├── FramebufferConverter.swift # BGRA→RGBA, CGImage, PNG encoding
│   │   │   └── CursorState.swift          # Cursor shape + position tracking
│   │   ├── Input/
│   │   │   ├── VNCInput.swift             # Keyboard + mouse operations
│   │   │   └── PlatformKeymap.swift       # Platform-aware keysym mapping
│   │   ├── SSH/
│   │   │   ├── SSHClient.swift            # SSH connection manager (ControlMaster)
│   │   │   └── SCPTransfer.swift          # SCP file upload/download
│   │   └── Capture/
│   │       └── StreamingCapture.swift     # AVAssetWriter video recording
│   └── guivision/                         # CLI target
│       ├── GUIVisionCLI.swift             # Root command + shared options
│       ├── ScreenshotCommand.swift        # screenshot subcommand
│       ├── InputCommand.swift             # key/type/click/scroll/drag subcommands
│       ├── SSHCommand.swift               # exec/upload/download subcommands
│       └── RecordCommand.swift            # record subcommand
├── Tests/
│   ├── TestSupport/                       # Shared test infrastructure
│   │   ├── VMManager.swift                # tart CLI wrapper (clone, start, stop, parse VNC URL)
│   │   └── VMTestEnvironment.swift        # Lazy VM lifecycle: create once, start/stop per suite
│   ├── GUIVisionVMDriverTests/
│   │   ├── Connection/
│   │   │   └── ConnectionSpecTests.swift
│   │   ├── VNC/
│   │   │   ├── FramebufferConverterTests.swift
│   │   │   ├── VNCCaptureTests.swift
│   │   │   └── CursorStateTests.swift
│   │   ├── Input/
│   │   │   ├── PlatformKeymapTests.swift
│   │   │   └── VNCInputTests.swift
│   │   ├── SSH/
│   │   │   ├── SSHClientTests.swift
│   │   │   └── SCPTransferTests.swift
│   │   └── Capture/
│   │       └── StreamingCaptureTests.swift
│   └── IntegrationTests/                  # Tests requiring a running VM
│       └── VNCIntegrationTests.swift
└── docs/
```

---

## Phase 1: Foundation

### Task 1: Project Scaffolding

**Files:**
- Create: `Package.swift`
- Copy: `LocalPackages/royalvnc/` (from `../TestAnywareRedux/LocalPackages/royalvnc/`)
- Create: `Sources/GUIVisionVMDriver/GUIVisionVMDriver.swift` (module export)
- Create: `Tests/GUIVisionVMDriverTests/SmokeTests.swift`

- [ ] **Step 1: Copy vendored RoyalVNCKit**

```bash
cp -R ../TestAnywareRedux/LocalPackages /Users/antony/Development/GUIVisionVMDriver/
```

- [ ] **Step 2: Create Package.swift**

```swift
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
        // MARK: - Test support library
        .target(
            name: "TestSupport",
            dependencies: [
                "GUIVisionVMDriver",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/TestSupport"
        ),

        // MARK: - Unit tests
        .testTarget(
            name: "GUIVisionVMDriverTests",
            dependencies: [
                "GUIVisionVMDriver",
                "TestSupport",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/GUIVisionVMDriverTests"
        ),

        // MARK: - Integration tests (require tart VM)
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "GUIVisionVMDriver",
                "TestSupport",
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ],
            path: "Tests/IntegrationTests"
        ),
    ]
)
```

- [ ] **Step 3: Create library module file**

Create `Sources/GUIVisionVMDriver/GUIVisionVMDriver.swift`:

```swift
// GUIVisionVMDriver — VNC + SSH driver for virtual machine automation.
// Re-exports for convenience.
@_exported import struct CoreGraphics.CGImage
@_exported import struct CoreGraphics.CGRect
@_exported import struct CoreGraphics.CGSize
@_exported import struct CoreGraphics.CGPoint
```

- [ ] **Step 4: Create minimal CLI entry point**

Create `Sources/guivision/GUIVisionCLI.swift`:

```swift
import ArgumentParser

@main
struct GUIVisionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision",
        abstract: "VNC + SSH driver for virtual machine automation",
        version: "0.1.0"
    )

    mutating func run() async throws {
        print("guivision 0.1.0 — use --help for available commands")
    }
}
```

- [ ] **Step 5: Create TestSupport placeholder**

Create `Tests/TestSupport/TestSupport.swift`:

```swift
// TestSupport — shared test infrastructure for VM management.
// Tasks 14-15 will populate this with VMManager and VMTestEnvironment.
```

Create `Tests/IntegrationTests/IntegrationPlaceholder.swift`:

```swift
// Integration tests — require a tart macOS VM.
// Populated in Task 15.
import Testing

@Suite("Integration Placeholder")
struct IntegrationPlaceholder {
    @Test func placeholder() {
        // Replaced by real integration tests in Task 15.
    }
}
```

- [ ] **Step 6: Create smoke test**

Create `Tests/GUIVisionVMDriverTests/SmokeTests.swift`:

```swift
import Testing
@testable import GUIVisionVMDriver

@Suite("Smoke")
struct SmokeTests {
    @Test func moduleImports() {
        // Verifies the module compiles and can be imported.
        #expect(true)
    }
}
```

- [ ] **Step 7: Build and test**

```bash
cd /Users/antony/Development/GUIVisionVMDriver
swift build
swift test
```

Expected: Build succeeds. 2 tests pass (smoke + integration placeholder).

- [ ] **Step 8: Commit**

```bash
git init
git add Package.swift LocalPackages Sources Tests README.md LICENSE docs
git commit -m "feat: project scaffolding with RoyalVNCKit, library, CLI, and test targets"
```

---

### Task 2: Platform and Connection Types

**Files:**
- Create: `Sources/GUIVisionVMDriver/Connection/Platform.swift`
- Create: `Sources/GUIVisionVMDriver/Connection/ConnectionSpec.swift`
- Create: `Tests/GUIVisionVMDriverTests/Connection/ConnectionSpecTests.swift`

- [ ] **Step 1: Write failing tests for Platform enum**

Create `Tests/GUIVisionVMDriverTests/Connection/ConnectionSpecTests.swift`:

```swift
import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("ConnectionSpec")
struct ConnectionSpecTests {

    // MARK: - Platform

    @Test func platformRawValues() {
        #expect(Platform.macos.rawValue == "macos")
        #expect(Platform.windows.rawValue == "windows")
        #expect(Platform.linux.rawValue == "linux")
    }

    @Test func platformDecodesFromJSON() throws {
        let json = Data(#""windows""#.utf8)
        let platform = try JSONDecoder().decode(Platform.self, from: json)
        #expect(platform == .windows)
    }

    // MARK: - VNCSpec

    @Test func vncSpecDefaults() {
        let spec = VNCSpec(host: "myhost")
        #expect(spec.host == "myhost")
        #expect(spec.port == 5900)
        #expect(spec.password == nil)
    }

    @Test func vncSpecCustomPort() {
        let spec = VNCSpec(host: "myhost", port: 5901, password: "secret")
        #expect(spec.port == 5901)
        #expect(spec.password == "secret")
    }

    // MARK: - SSHSpec

    @Test func sshSpecDefaults() {
        let spec = SSHSpec(host: "myhost", user: "admin")
        #expect(spec.port == 22)
        #expect(spec.key == nil)
        #expect(spec.password == nil)
    }

    // MARK: - ConnectionSpec JSON decoding

    @Test func decodesFullSpec() throws {
        let json = """
        {
            "vnc": { "host": "localhost", "port": 5900, "password": "abc123" },
            "ssh": { "host": "localhost", "port": 22, "user": "admin", "key": "~/.ssh/id_ed25519" },
            "platform": "windows"
        }
        """
        let spec = try JSONDecoder().decode(ConnectionSpec.self, from: Data(json.utf8))

        #expect(spec.vnc.host == "localhost")
        #expect(spec.vnc.port == 5900)
        #expect(spec.vnc.password == "abc123")
        #expect(spec.ssh?.user == "admin")
        #expect(spec.ssh?.key == "~/.ssh/id_ed25519")
        #expect(spec.platform == .windows)
    }

    @Test func decodesMinimalSpec() throws {
        let json = """
        { "vnc": { "host": "192.168.1.100", "port": 5901 } }
        """
        let spec = try JSONDecoder().decode(ConnectionSpec.self, from: Data(json.utf8))

        #expect(spec.vnc.host == "192.168.1.100")
        #expect(spec.vnc.port == 5901)
        #expect(spec.ssh == nil)
        #expect(spec.platform == nil)
    }

    // MARK: - CLI endpoint parsing

    @Test func parsesVNCEndpoint() throws {
        let spec = try ConnectionSpec.from(vnc: "myhost:5901")
        #expect(spec.vnc.host == "myhost")
        #expect(spec.vnc.port == 5901)
    }

    @Test func parsesVNCEndpointDefaultPort() throws {
        let spec = try ConnectionSpec.from(vnc: "myhost")
        #expect(spec.vnc.host == "myhost")
        #expect(spec.vnc.port == 5900)
    }

    @Test func parsesSSHEndpoint() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", ssh: "admin@myhost:2222")
        #expect(spec.ssh?.user == "admin")
        #expect(spec.ssh?.host == "myhost")
        #expect(spec.ssh?.port == 2222)
    }

    @Test func parsesSSHEndpointDefaultPort() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", ssh: "root@10.0.0.1")
        #expect(spec.ssh?.user == "root")
        #expect(spec.ssh?.host == "10.0.0.1")
        #expect(spec.ssh?.port == 22)
    }

    @Test func parsesPlatform() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", platform: "macos")
        #expect(spec.platform == .macos)
    }

    @Test func rejectsInvalidPlatform() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: "localhost", platform: "android")
        }
    }

    @Test func rejectsInvalidSSHEndpoint() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: "localhost", ssh: "noatsign")
        }
    }

    @Test func rejectsEmptyHost() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: ":5900")
        }
    }

    @Test func rejectsInvalidPort() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: "localhost:99999")
        }
    }

    @Test func encodesAndDecodesRoundtrip() throws {
        let original = ConnectionSpec(
            vnc: VNCSpec(host: "10.0.0.5", port: 5902, password: "secret"),
            ssh: SSHSpec(host: "10.0.0.5", port: 22, user: "testuser", key: "~/.ssh/id_rsa"),
            platform: .linux
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionSpec.self, from: data)
        #expect(decoded.vnc.host == original.vnc.host)
        #expect(decoded.vnc.port == original.vnc.port)
        #expect(decoded.vnc.password == original.vnc.password)
        #expect(decoded.ssh?.user == original.ssh?.user)
        #expect(decoded.platform == original.platform)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter ConnectionSpecTests 2>&1 | head -20
```

Expected: Compilation errors — `Platform`, `VNCSpec`, `ConnectionSpec` not found.

- [ ] **Step 3: Implement Platform enum**

Create `Sources/GUIVisionVMDriver/Connection/Platform.swift`:

```swift
import Foundation

/// Target platform hint, used for keysym mapping.
public enum Platform: String, Codable, Sendable {
    case macos
    case windows
    case linux
}
```

- [ ] **Step 4: Implement ConnectionSpec**

Create `Sources/GUIVisionVMDriver/Connection/ConnectionSpec.swift`:

```swift
import Foundation

// MARK: - Spec Types

/// VNC connection parameters. Required for all connections.
public struct VNCSpec: Codable, Sendable {
    public let host: String
    public let port: Int
    public let password: String?

    public init(host: String, port: Int = 5900, password: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
    }
}

/// SSH connection parameters. Optional — enables shell access and file transfer.
public struct SSHSpec: Codable, Sendable {
    public let host: String
    public let port: Int
    public let user: String
    public let key: String?
    public let password: String?

    public init(host: String, port: Int = 22, user: String, key: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.key = key
        self.password = password
    }
}

/// Complete connection specification for a target machine.
/// Only `vnc` is required. SSH adds shell access and file transfer.
public struct ConnectionSpec: Codable, Sendable {
    public let vnc: VNCSpec
    public let ssh: SSHSpec?
    public let platform: Platform?

    public init(vnc: VNCSpec, ssh: SSHSpec? = nil, platform: Platform? = nil) {
        self.vnc = vnc
        self.ssh = ssh
        self.platform = platform
    }
}

// MARK: - Loading

extension ConnectionSpec {
    /// Load a connection spec from a JSON file.
    public static func load(from path: String) throws -> ConnectionSpec {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConnectionSpec.self, from: data)
    }

    /// Construct a connection spec from CLI flag values.
    public static func from(
        vnc: String,
        ssh: String? = nil,
        platform: String? = nil
    ) throws -> ConnectionSpec {
        let vncSpec = try parseVNCEndpoint(vnc)
        let sshSpec = try ssh.map { try parseSSHEndpoint($0) }
        let platformValue = try platform.map { try parsePlatform($0) }
        return ConnectionSpec(vnc: vncSpec, ssh: sshSpec, platform: platformValue)
    }
}

// MARK: - Endpoint Parsing

extension ConnectionSpec {
    static func parseVNCEndpoint(_ endpoint: String) throws -> VNCSpec {
        let (host, port) = try parseHostPort(endpoint, defaultPort: 5900)
        return VNCSpec(host: host, port: port)
    }

    static func parseSSHEndpoint(_ endpoint: String) throws -> SSHSpec {
        guard let atIndex = endpoint.firstIndex(of: "@") else {
            throw ConnectionSpecError.invalidSSHEndpoint(endpoint)
        }
        let user = String(endpoint[endpoint.startIndex..<atIndex])
        let hostPart = String(endpoint[endpoint.index(after: atIndex)...])
        let (host, port) = try parseHostPort(hostPart, defaultPort: 22)
        return SSHSpec(host: host, port: port, user: user)
    }

    static func parsePlatform(_ value: String) throws -> Platform {
        guard let platform = Platform(rawValue: value.lowercased()) else {
            throw ConnectionSpecError.invalidPlatform(value)
        }
        return platform
    }

    private static func parseHostPort(_ endpoint: String, defaultPort: Int) throws -> (String, Int) {
        let parts = endpoint.split(separator: ":", maxSplits: 1)
        let host = String(parts[0])
        if host.isEmpty {
            throw ConnectionSpecError.emptyHost
        }
        if parts.count == 2 {
            guard let port = Int(parts[1]), port > 0, port <= 65535 else {
                throw ConnectionSpecError.invalidPort(String(parts[1]))
            }
            return (host, port)
        }
        return (host, defaultPort)
    }
}

// MARK: - Errors

public enum ConnectionSpecError: LocalizedError {
    case invalidSSHEndpoint(String)
    case invalidPlatform(String)
    case emptyHost
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSSHEndpoint(let endpoint):
            "Invalid SSH endpoint '\(endpoint)'. Expected format: user@host[:port]"
        case .invalidPlatform(let value):
            "Invalid platform '\(value)'. Expected: macos, windows, or linux"
        case .emptyHost:
            "Host cannot be empty"
        case .invalidPort(let port):
            "Invalid port '\(port)'. Expected a number between 1 and 65535"
        }
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

```bash
swift test --filter ConnectionSpecTests
```

Expected: All 15 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GUIVisionVMDriver/Connection Tests/GUIVisionVMDriverTests/Connection
git commit -m "feat: connection spec types with JSON decoding and CLI parsing"
```

---

### Task 3: Framebuffer Converter

**Files:**
- Create: `Sources/GUIVisionVMDriver/VNC/FramebufferConverter.swift`
- Create: `Tests/GUIVisionVMDriverTests/VNC/FramebufferConverterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/GUIVisionVMDriverTests/VNC/FramebufferConverterTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import GUIVisionVMDriver

@Suite("FramebufferConverter")
struct FramebufferConverterTests {
    @Test func swapsBGRAtoRGBA() {
        var bgra: [UInt8] = [255, 0, 0, 255]  // B=255, G=0, R=0, A=255
        FramebufferConverter.bgraToRGBA(&bgra)
        #expect(bgra == [0, 0, 255, 255])  // R=0, G=0, B=255, A=255
    }

    @Test func swapsMultiplePixels() {
        var bgra: [UInt8] = [
            0, 0, 255, 255,    // BGRA red pixel
            0, 255, 0, 255,    // BGRA green pixel
        ]
        FramebufferConverter.bgraToRGBA(&bgra)
        #expect(bgra == [
            255, 0, 0, 255,    // RGBA red pixel
            0, 255, 0, 255,    // RGBA green pixel (G unchanged)
        ])
    }

    @Test func createsCGImageFromRGBA() throws {
        let rgba: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        let image = try FramebufferConverter.cgImage(fromRGBA: rgba, width: 2, height: 2)
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test func encodesPNG() throws {
        let rgba: [UInt8] = Array(repeating: UInt8(128), count: 4 * 10 * 10)
        let image = try FramebufferConverter.cgImage(fromRGBA: rgba, width: 10, height: 10)
        let png = try FramebufferConverter.pngData(from: image)
        #expect(png[0] == 0x89)  // PNG magic
        #expect(png[1] == 0x50)  // P
        #expect(png[2] == 0x4E)  // N
        #expect(png[3] == 0x47)  // G
    }

    @Test func rejectsZeroDimensions() {
        #expect(throws: FramebufferConverterError.self) {
            try FramebufferConverter.cgImage(fromRGBA: [], width: 0, height: 0)
        }
    }

    @Test func rejectsMismatchedPixelCount() {
        let rgba: [UInt8] = [255, 0, 0, 255]  // 1 pixel
        #expect(throws: FramebufferConverterError.self) {
            try FramebufferConverter.cgImage(fromRGBA: rgba, width: 2, height: 2)
        }
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter FramebufferConverterTests 2>&1 | head -10
```

Expected: Compilation error — `FramebufferConverter` not found.

- [ ] **Step 3: Implement FramebufferConverter**

Create `Sources/GUIVisionVMDriver/VNC/FramebufferConverter.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FramebufferConverter {
    /// Swap BGRA pixel buffer to RGBA in-place.
    public static func bgraToRGBA(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels.swapAt(i, i + 2)
        }
    }

    /// Create a CGImage from an RGBA pixel buffer.
    public static func cgImage(fromRGBA pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw FramebufferConverterError.invalidDimensions(width, height)
        }
        guard pixels.count == width * height * 4 else {
            throw FramebufferConverterError.pixelCountMismatch(
                expected: width * height * 4, actual: pixels.count
            )
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let result: CGImage? = pixels.withUnsafeBytes { buffer in
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image = result else {
            throw FramebufferConverterError.cgContextFailed
        }
        return image
    }

    /// Encode a CGImage as PNG data.
    public static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw FramebufferConverterError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FramebufferConverterError.pngEncodingFailed
        }
        return data as Data
    }
}

public enum FramebufferConverterError: Error, LocalizedError {
    case invalidDimensions(Int, Int)
    case pixelCountMismatch(expected: Int, actual: Int)
    case cgContextFailed
    case pngEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let w, let h):
            "Invalid dimensions: \(w)x\(h)"
        case .pixelCountMismatch(let expected, let actual):
            "Pixel count mismatch: expected \(expected), got \(actual)"
        case .cgContextFailed:
            "Failed to create CGContext"
        case .pngEncodingFailed:
            "Failed to encode PNG"
        }
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter FramebufferConverterTests
```

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GUIVisionVMDriver/VNC/FramebufferConverter.swift Tests/GUIVisionVMDriverTests/VNC/FramebufferConverterTests.swift
git commit -m "feat: framebuffer converter (BGRA→RGBA, CGImage, PNG encoding)"
```

---

## Phase 2: VNC Connection

### Task 4: VNC Errors and Cursor State

**Files:**
- Create: `Sources/GUIVisionVMDriver/VNC/VNCCaptureError.swift`
- Create: `Sources/GUIVisionVMDriver/VNC/CursorState.swift`
- Create: `Tests/GUIVisionVMDriverTests/VNC/CursorStateTests.swift`

- [ ] **Step 1: Write failing tests for CursorState**

Create `Tests/GUIVisionVMDriverTests/VNC/CursorStateTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import GUIVisionVMDriver

@Suite("CursorState")
struct CursorStateTests {
    @Test func defaultsToNil() {
        let state = CursorState()
        #expect(state.position == nil)
        #expect(state.hotspot == nil)
        #expect(state.size == nil)
    }

    @Test func updatesPosition() {
        var state = CursorState()
        state.update(position: CGPoint(x: 100, y: 200))
        #expect(state.position == CGPoint(x: 100, y: 200))
    }

    @Test func updatesCursorShape() {
        var state = CursorState()
        state.update(size: CGSize(width: 16, height: 16), hotspot: CGPoint(x: 8, y: 8))
        #expect(state.size == CGSize(width: 16, height: 16))
        #expect(state.hotspot == CGPoint(x: 8, y: 8))
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter CursorStateTests 2>&1 | head -10
```

Expected: Compilation error — `CursorState` not found.

- [ ] **Step 3: Implement VNCCaptureError**

Create `Sources/GUIVisionVMDriver/VNC/VNCCaptureError.swift`:

```swift
import Foundation

public enum VNCCaptureError: Error, CustomStringConvertible, Sendable {
    case notConfigured
    case connectionFailed(String)
    case disconnected
    case framebufferNotReady
    case captureFailed
    case encodingFailed
    case timeout

    public var description: String {
        switch self {
        case .notConfigured:
            "VNC not configured: call connect() first"
        case .connectionFailed(let detail):
            "VNC connection failed: \(detail)"
        case .disconnected:
            "VNC connection lost"
        case .framebufferNotReady:
            "VNC framebuffer not ready"
        case .captureFailed:
            "Failed to capture VNC framebuffer"
        case .encodingFailed:
            "Failed to encode PNG"
        case .timeout:
            "VNC connection timed out"
        }
    }
}
```

- [ ] **Step 4: Implement CursorState**

Create `Sources/GUIVisionVMDriver/VNC/CursorState.swift`:

```swift
import CoreGraphics

/// Tracks cursor shape and position as reported by the VNC server.
public struct CursorState: Sendable {
    /// Current cursor position in framebuffer coordinates.
    public private(set) var position: CGPoint?
    /// Cursor hotspot offset within the cursor image.
    public private(set) var hotspot: CGPoint?
    /// Cursor image dimensions.
    public private(set) var size: CGSize?
    /// Raw cursor pixel data (RGBA).
    public private(set) var imageData: [UInt8]?

    public init() {}

    public mutating func update(position: CGPoint) {
        self.position = position
    }

    public mutating func update(size: CGSize, hotspot: CGPoint, imageData: [UInt8]? = nil) {
        self.size = size
        self.hotspot = hotspot
        self.imageData = imageData
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

```bash
swift test --filter CursorStateTests
```

Expected: All 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GUIVisionVMDriver/VNC/VNCCaptureError.swift Sources/GUIVisionVMDriver/VNC/CursorState.swift Tests/GUIVisionVMDriverTests/VNC/CursorStateTests.swift
git commit -m "feat: VNC error types and cursor state tracking"
```

---

### Task 5: VNC Capture Delegate

**Files:**
- Create: `Sources/GUIVisionVMDriver/VNC/VNCCaptureDelegate.swift`

This is infrastructure code that bridges RoyalVNCKit callbacks to Swift concurrency. It cannot be meaningfully unit-tested in isolation (requires a real VNC connection), but its thread-safety design is critical.

- [ ] **Step 1: Implement VNCCaptureDelegate**

Create `Sources/GUIVisionVMDriver/VNC/VNCCaptureDelegate.swift`:

```swift
import Foundation
import CoreGraphics
@preconcurrency import RoyalVNCKit

/// Bridge between RoyalVNCKit delegate callbacks and Swift concurrency.
/// Thread-safe via `NSLock`. Stores framebuffer state, cursor state, and
/// signals readiness to waiting `connect()` calls via `CheckedContinuation`.
final class VNCCaptureDelegate: VNCConnectionDelegate, @unchecked Sendable {

    private let lock = NSLock()

    // Credentials
    private let password: String?

    // Framebuffer state (guarded by lock)
    private var _framebuffer: VNCFramebuffer?
    private var _isFramebufferReady = false

    // Cursor state (guarded by lock)
    private var _cursorState = CursorState()

    // Connect continuation (guarded by lock)
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var disconnectError: (any Error)?

    init(password: String?) {
        self.password = password
    }

    // MARK: - Thread-safe accessors

    var framebuffer: VNCFramebuffer? {
        lock.withLock { _framebuffer }
    }

    var isFramebufferReady: Bool {
        lock.withLock { _isFramebufferReady }
    }

    var cursorState: CursorState {
        lock.withLock { _cursorState }
    }

    /// Register a continuation to be resumed on first framebuffer update or error.
    func setConnectContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if _isFramebufferReady {
            continuation.resume()
        } else if let error = disconnectError {
            continuation.resume(throwing: error)
        } else {
            connectContinuation = continuation
        }
    }

    /// Resume any pending continuation with an error (used by timeout timer).
    func resumeIfPending(with error: any Error) {
        lock.lock()
        let continuation = connectContinuation
        connectContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    // MARK: - VNCConnectionDelegate

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .connected:
            break
        case .disconnected:
            lock.lock()
            let error = connectionState.error
            let continuation = connectContinuation
            connectContinuation = nil
            _isFramebufferReady = false
            disconnectError = error
            lock.unlock()

            if let continuation {
                continuation.resume(throwing: error ?? VNCCaptureError.disconnected)
            }
        case .connecting, .disconnecting:
            break
        @unknown default:
            break
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        switch authenticationType {
        case .vnc:
            completion(VNCPasswordCredential(password: password ?? ""))
        case .appleRemoteDesktop:
            completion(VNCUsernamePasswordCredential(username: "", password: password ?? ""))
        default:
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection,
                    didCreateFramebuffer framebuffer: VNCFramebuffer) {
        lock.withLock { _framebuffer = framebuffer }
    }

    func connection(_ connection: VNCConnection,
                    didResizeFramebuffer framebuffer: VNCFramebuffer) {
        lock.withLock { _framebuffer = framebuffer }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16,
                    width: UInt16, height: UInt16) {
        lock.lock()
        _framebuffer = framebuffer
        let wasReady = _isFramebufferReady
        _isFramebufferReady = true
        let continuation = connectContinuation
        connectContinuation = nil
        lock.unlock()

        if !wasReady, let continuation {
            continuation.resume()
        }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateCursor cursor: VNCCursor) {
        lock.lock()
        _cursorState.update(
            size: CGSize(width: CGFloat(cursor.size.width), height: CGFloat(cursor.size.height)),
            hotspot: CGPoint(x: CGFloat(cursor.hotspot.x), y: CGFloat(cursor.hotspot.y))
        )
        lock.unlock()
    }
}
```

- [ ] **Step 2: Verify project compiles**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 3: Commit**

```bash
git add Sources/GUIVisionVMDriver/VNC/VNCCaptureDelegate.swift
git commit -m "feat: VNC capture delegate with cursor tracking"
```

---

### Task 6: VNC Capture Actor

**Files:**
- Create: `Sources/GUIVisionVMDriver/VNC/VNCCapture.swift`
- Create: `Tests/GUIVisionVMDriverTests/VNC/VNCCaptureTests.swift`

- [ ] **Step 1: Write failing tests for VNCCapture**

Create `Tests/GUIVisionVMDriverTests/VNC/VNCCaptureTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import GUIVisionVMDriver

@Suite("VNCCapture")
struct VNCCaptureTests {
    @Test func initFromSpec() async {
        let spec = VNCSpec(host: "testhost", port: 5901, password: "pass")
        let capture = VNCCapture(spec: spec)
        let size = await capture.screenSize()
        #expect(size == nil)  // not connected yet
    }

    @Test func initFromHostPort() async {
        let capture = VNCCapture(host: "localhost", port: 5900)
        let size = await capture.screenSize()
        #expect(size == nil)
    }

    @Test func captureImageThrowsWhenNotConnected() async {
        let capture = VNCCapture(host: "localhost")
        do {
            _ = try await capture.captureImage()
            Issue.record("Expected VNCCaptureError.notConfigured")
        } catch {
            #expect(error is VNCCaptureError)
        }
    }

    @Test func withConnectionThrowsWhenNotConnected() async {
        let capture = VNCCapture(host: "localhost")
        do {
            _ = try await capture.withConnection { _ in 42 }
            Issue.record("Expected VNCCaptureError.notConfigured")
        } catch {
            #expect(error is VNCCaptureError)
        }
    }

    @Test func cursorStateStartsEmpty() async {
        let capture = VNCCapture(host: "localhost")
        let cursor = await capture.cursorState
        #expect(cursor.position == nil)
        #expect(cursor.size == nil)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter VNCCaptureTests 2>&1 | head -10
```

Expected: Compilation error — `VNCCapture` not found.

- [ ] **Step 3: Implement VNCCapture**

Create `Sources/GUIVisionVMDriver/VNC/VNCCapture.swift`:

```swift
import CoreGraphics
import Foundation
@preconcurrency import RoyalVNCKit

/// Persistent VNC connection for screen capture, input, and cursor tracking.
public actor VNCCapture {

    private let spec: VNCSpec

    private nonisolated(unsafe) var connection: VNCConnection?
    private nonisolated(unsafe) var delegate: VNCCaptureDelegate?

    // MARK: - Init

    public init(spec: VNCSpec) {
        self.spec = spec
    }

    public init(host: String, port: Int = 5900, password: String? = nil) {
        self.spec = VNCSpec(host: host, port: port, password: password)
    }

    // MARK: - Connect / Disconnect

    /// Connect to the VNC server and wait for the first framebuffer update.
    public func connect(timeout: Duration = .seconds(30)) async throws {
        disconnect()

        let del = VNCCaptureDelegate(password: spec.password)

        let debugVNC = ProcessInfo.processInfo.environment["GUIVISION_VNC_DEBUG"] == "1"
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: debugVNC,
            hostname: spec.host,
            port: UInt16(spec.port),
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardAllKeyboardShortcutsAndHotKeys,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        let conn = VNCConnection(settings: settings)
        conn.delegate = del

        self.delegate = del
        self.connection = conn

        conn.connect()

        let timeoutSeconds = Int(timeout.components.seconds)
        let timeoutItem = DispatchWorkItem { [weak del] in
            del?.resumeIfPending(with: VNCCaptureError.timeout)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds),
            execute: timeoutItem
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                del.setConnectContinuation(continuation)
            }
            timeoutItem.cancel()
        } catch {
            timeoutItem.cancel()
            throw error
        }
    }

    /// Disconnect from the VNC server and release resources.
    public func disconnect() {
        connection?.disconnect()
        connection = nil
        delegate = nil
    }

    // MARK: - Screen Capture

    /// Capture the current framebuffer as a CGImage.
    public func captureImage(region: CGRect? = nil) async throws -> CGImage {
        guard let currentDelegate = delegate else {
            throw VNCCaptureError.notConfigured
        }

        if !currentDelegate.isFramebufferReady {
            try await connect()
        }

        guard let activeDelegate = self.delegate,
              let framebuffer = activeDelegate.framebuffer else {
            throw VNCCaptureError.framebufferNotReady
        }

        let fullImage = try Self.cgImageFromFramebuffer(framebuffer)

        if let region {
            guard let cropped = fullImage.cropping(to: region) else {
                throw VNCCaptureError.captureFailed
            }
            return cropped
        }
        return fullImage
    }

    /// Capture a screenshot as PNG data.
    public func screenshot(region: CGRect? = nil) async throws -> Data {
        let image = try await captureImage(region: region)
        return try FramebufferConverter.pngData(from: image)
    }

    // MARK: - Screen Metadata

    /// Return framebuffer dimensions, or nil if not connected.
    public func screenSize() -> CGSize? {
        guard let framebuffer = delegate?.framebuffer else { return nil }
        return framebuffer.cgSize
    }

    // MARK: - Cursor

    /// Current cursor state (shape, position, hotspot).
    public var cursorState: CursorState {
        delegate?.cursorState ?? CursorState()
    }

    // MARK: - Low-level Connection Access

    /// Run a closure with direct access to the VNCConnection.
    public func withConnection<T: Sendable>(_ body: (VNCConnection) throws -> T) throws -> T {
        guard let conn = connection else {
            throw VNCCaptureError.notConfigured
        }
        return try body(conn)
    }

    // MARK: - Framebuffer → CGImage

    private static func cgImageFromFramebuffer(_ framebuffer: VNCFramebuffer) throws -> CGImage {
        let width = Int(framebuffer.size.width)
        let height = Int(framebuffer.size.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = width * height * bytesPerPixel

        guard framebuffer.surfaceByteCount == totalBytes else {
            throw VNCCaptureError.captureFailed
        }

        framebuffer.allocator.lockReadOnly()
        let rgbaData = NSMutableData(length: totalBytes)!
        let src = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)
        let dst = rgbaData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: totalBytes, by: bytesPerPixel) {
            dst[i + 0] = src[i + 2]  // R ← B
            dst[i + 1] = src[i + 1]  // G ← G
            dst[i + 2] = src[i + 0]  // B ← R
            dst[i + 3] = 255         // A
        }
        framebuffer.allocator.unlockReadOnly()

        guard let provider = CGDataProvider(data: rgbaData) else {
            throw VNCCaptureError.captureFailed
        }

        guard let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw VNCCaptureError.captureFailed
        }
        return image
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter VNCCaptureTests
```

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GUIVisionVMDriver/VNC/VNCCapture.swift Tests/GUIVisionVMDriverTests/VNC/VNCCaptureTests.swift
git commit -m "feat: VNC capture actor with connection, screenshot, and cursor access"
```

---

## Phase 3: Input

### Task 7: Platform Keymap

**Files:**
- Create: `Sources/GUIVisionVMDriver/Input/PlatformKeymap.swift`
- Create: `Tests/GUIVisionVMDriverTests/Input/PlatformKeymapTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/GUIVisionVMDriverTests/Input/PlatformKeymapTests.swift`:

```swift
import Testing
import RoyalVNCKit
@testable import GUIVisionVMDriver

@Suite("PlatformKeymap")
struct PlatformKeymapTests {

    // MARK: - Base key resolution

    @Test func resolvesLetterKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "a").rawValue == UInt32(UInt8(ascii: "a")))
        #expect(try PlatformKeymap.keyCode(for: "z").rawValue == UInt32(UInt8(ascii: "z")))
    }

    @Test func resolvesNumberKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "0").rawValue == UInt32(UInt8(ascii: "0")))
        #expect(try PlatformKeymap.keyCode(for: "9").rawValue == UInt32(UInt8(ascii: "9")))
    }

    @Test func resolvesSpecialKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "return") == .return)
        #expect(try PlatformKeymap.keyCode(for: "enter") == .return)
        #expect(try PlatformKeymap.keyCode(for: "tab") == .tab)
        #expect(try PlatformKeymap.keyCode(for: "escape") == .escape)
        #expect(try PlatformKeymap.keyCode(for: "space") == .space)
        #expect(try PlatformKeymap.keyCode(for: "delete") == .delete)
        #expect(try PlatformKeymap.keyCode(for: "backspace") == .delete)
    }

    @Test func resolvesArrowKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "up") == .upArrow)
        #expect(try PlatformKeymap.keyCode(for: "down") == .downArrow)
        #expect(try PlatformKeymap.keyCode(for: "left") == .leftArrow)
        #expect(try PlatformKeymap.keyCode(for: "right") == .rightArrow)
    }

    @Test func resolvesFunctionKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "f1") == .f1)
        #expect(try PlatformKeymap.keyCode(for: "f12") == .f12)
    }

    @Test func resolvesNavigationKeys() throws {
        #expect(try PlatformKeymap.keyCode(for: "home") == .home)
        #expect(try PlatformKeymap.keyCode(for: "end") == .end)
        #expect(try PlatformKeymap.keyCode(for: "pageup") == .pageUp)
        #expect(try PlatformKeymap.keyCode(for: "pagedown") == .pageDown)
    }

    @Test func isCaseInsensitive() throws {
        #expect(try PlatformKeymap.keyCode(for: "Return") == .return)
        #expect(try PlatformKeymap.keyCode(for: "ESCAPE") == .escape)
    }

    @Test func throwsForUnknownKey() {
        #expect(throws: PlatformKeymapError.self) {
            try PlatformKeymap.keyCode(for: "nonexistent")
        }
    }

    // MARK: - Platform-specific modifiers

    @Test func macOSCmdMapsToAltL() {
        let code = PlatformKeymap.modifierKeyCode(for: "cmd", platform: .macos)
        #expect(code == .option)  // XK_Alt_L → Cmd on Virtualization.framework
    }

    @Test func windowsCmdMapsToCtrl() {
        let code = PlatformKeymap.modifierKeyCode(for: "cmd", platform: .windows)
        #expect(code == .control)
    }

    @Test func linuxCmdMapsToCtrl() {
        let code = PlatformKeymap.modifierKeyCode(for: "cmd", platform: .linux)
        #expect(code == .control)
    }

    @Test func macOSAltMapsToMetaL() {
        let code = PlatformKeymap.modifierKeyCode(for: "alt", platform: .macos)
        #expect(code == .optionForARD)  // XK_Meta_L
    }

    @Test func windowsAltMapsToAltL() {
        let code = PlatformKeymap.modifierKeyCode(for: "alt", platform: .windows)
        #expect(code == .option)  // XK_Alt_L
    }

    @Test func shiftIsUniversal() {
        #expect(PlatformKeymap.modifierKeyCode(for: "shift", platform: .macos) == .shift)
        #expect(PlatformKeymap.modifierKeyCode(for: "shift", platform: .windows) == .shift)
        #expect(PlatformKeymap.modifierKeyCode(for: "shift", platform: .linux) == .shift)
    }

    @Test func ctrlIsUniversal() {
        #expect(PlatformKeymap.modifierKeyCode(for: "ctrl", platform: .macos) == .control)
        #expect(PlatformKeymap.modifierKeyCode(for: "ctrl", platform: .windows) == .control)
    }

    @Test func unknownModifierReturnsNil() {
        #expect(PlatformKeymap.modifierKeyCode(for: "unknown", platform: .macos) == nil)
    }

    @Test func defaultPlatformIsMacOS() {
        #expect(PlatformKeymap.modifierKeyCode(for: "cmd", platform: nil) == .option)
    }

    @Test func modifierIsCaseInsensitive() {
        #expect(PlatformKeymap.modifierKeyCode(for: "CMD", platform: .macos) == .option)
        #expect(PlatformKeymap.modifierKeyCode(for: "Shift", platform: .windows) == .shift)
    }

    // MARK: - Mouse buttons

    @Test func resolvesMouseButtons() throws {
        #expect(try PlatformKeymap.mouseButton(for: "left") == .left)
        #expect(try PlatformKeymap.mouseButton(for: "right") == .right)
        #expect(try PlatformKeymap.mouseButton(for: "middle") == .middle)
        #expect(try PlatformKeymap.mouseButton(for: "center") == .middle)
    }

    @Test func mouseButtonIsCaseInsensitive() throws {
        #expect(try PlatformKeymap.mouseButton(for: "Left") == .left)
        #expect(try PlatformKeymap.mouseButton(for: "RIGHT") == .right)
    }

    @Test func throwsForUnknownMouseButton() {
        #expect(throws: PlatformKeymapError.self) {
            try PlatformKeymap.mouseButton(for: "extra")
        }
    }

    // MARK: - Scroll decomposition

    @Test func decomposesScrollUp() {
        let components = PlatformKeymap.decomposeScroll(deltaX: 0, deltaY: -3)
        #expect(components == [.init(direction: .up, steps: 3)])
    }

    @Test func decomposesScrollDown() {
        let components = PlatformKeymap.decomposeScroll(deltaX: 0, deltaY: 3)
        #expect(components == [.init(direction: .down, steps: 3)])
    }

    @Test func decomposesScrollBothAxes() {
        let components = PlatformKeymap.decomposeScroll(deltaX: 2, deltaY: -1)
        #expect(components == [
            .init(direction: .up, steps: 1),
            .init(direction: .right, steps: 2),
        ])
    }

    @Test func decomposesScrollZero() {
        #expect(PlatformKeymap.decomposeScroll(deltaX: 0, deltaY: 0).isEmpty)
    }

    // MARK: - Batch modifier resolution

    @Test func resolvesMultipleModifiers() {
        let codes = PlatformKeymap.resolveModifiers(["cmd", "shift"], platform: .macos)
        #expect(codes.count == 2)
        #expect(codes.contains(.option))
        #expect(codes.contains(.shift))
    }

    @Test func resolveModifiersFiltersUnknown() {
        let codes = PlatformKeymap.resolveModifiers(["shift", "bogus", "ctrl"], platform: .macos)
        #expect(codes.count == 2)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter PlatformKeymapTests 2>&1 | head -10
```

Expected: Compilation error — `PlatformKeymap` not found.

- [ ] **Step 3: Implement PlatformKeymap**

Create `Sources/GUIVisionVMDriver/Input/PlatformKeymap.swift`:

```swift
import Foundation
@preconcurrency import RoyalVNCKit

/// Platform-aware keysym mapping for VNC input.
public enum PlatformKeymap {

    // MARK: - Key resolution

    public static func keyCode(for key: String) throws -> VNCKeyCode {
        guard let code = keyCodes[key.lowercased()] else {
            throw PlatformKeymapError.unknownKey(key)
        }
        return code
    }

    public static func modifierKeyCode(for modifier: String, platform: Platform?) -> VNCKeyCode? {
        modifierKeyCodes(for: platform ?? .macos)[modifier.lowercased()]
    }

    public static func resolveModifiers(_ modifiers: [String], platform: Platform?) -> [VNCKeyCode] {
        modifiers.compactMap { modifierKeyCode(for: $0, platform: platform) }
    }

    // MARK: - Mouse

    public static func mouseButton(for name: String) throws -> VNCMouseButton {
        guard let button = mouseButtons[name.lowercased()] else {
            throw PlatformKeymapError.unknownButton(name)
        }
        return button
    }

    // MARK: - Scroll

    public struct ScrollComponent: Equatable, Sendable {
        public let direction: VNCMouseWheel
        public let steps: UInt32

        public init(direction: VNCMouseWheel, steps: UInt32) {
            self.direction = direction
            self.steps = steps
        }
    }

    public static func decomposeScroll(deltaX: Int, deltaY: Int) -> [ScrollComponent] {
        var components: [ScrollComponent] = []
        if deltaY < 0 {
            components.append(.init(direction: .up, steps: UInt32(abs(deltaY))))
        } else if deltaY > 0 {
            components.append(.init(direction: .down, steps: UInt32(deltaY)))
        }
        if deltaX < 0 {
            components.append(.init(direction: .left, steps: UInt32(abs(deltaX))))
        } else if deltaX > 0 {
            components.append(.init(direction: .right, steps: UInt32(deltaX)))
        }
        return components
    }

    // MARK: - Shifted character map

    /// Characters requiring Shift on a US keyboard → their unshifted base ASCII value.
    static let shiftedCharToBase: [Character: UInt8] = [
        "!": 0x31, "@": 0x32, "#": 0x33, "$": 0x34, "%": 0x35,
        "^": 0x36, "&": 0x37, "*": 0x38, "(": 0x39, ")": 0x30,
        "~": 0x60, "_": 0x2d, "+": 0x3d,
        "{": 0x5b, "}": 0x5d, "|": 0x5c,
        ":": 0x3b, "\"": 0x27,
        "<": 0x2c, ">": 0x2e, "?": 0x2f,
    ]

    // MARK: - Key tables

    private nonisolated(unsafe) static let keyCodes: [String: VNCKeyCode] = {
        var map: [String: VNCKeyCode] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz" {
            map[String(c)] = VNCKeyCode(asciiCharacter: c.asciiValue!)
        }
        for c in "0123456789" {
            map[String(c)] = VNCKeyCode(asciiCharacter: c.asciiValue!)
        }
        map["return"] = .return
        map["enter"] = .return
        map["tab"] = .tab
        map["escape"] = .escape
        map["esc"] = .escape
        map["space"] = .space
        map["delete"] = .delete
        map["backspace"] = .delete
        map["forwarddelete"] = .forwardDelete
        map["up"] = .upArrow
        map["down"] = .downArrow
        map["left"] = .leftArrow
        map["right"] = .rightArrow
        map["home"] = .home
        map["end"] = .end
        map["pageup"] = .pageUp
        map["pagedown"] = .pageDown
        map["f1"] = .f1;  map["f2"] = .f2;  map["f3"] = .f3;  map["f4"] = .f4
        map["f5"] = .f5;  map["f6"] = .f6;  map["f7"] = .f7;  map["f8"] = .f8
        map["f9"] = .f9;  map["f10"] = .f10; map["f11"] = .f11; map["f12"] = .f12
        return map
    }()

    private static func modifierKeyCodes(for platform: Platform) -> [String: VNCKeyCode] {
        switch platform {
        case .macos:
            return [
                "cmd": .option, "command": .option,       // XK_Alt_L → Cmd
                "alt": .optionForARD, "option": .optionForARD,  // XK_Meta_L → Option
                "shift": .shift,
                "ctrl": .control, "control": .control,
            ]
        case .windows, .linux:
            return [
                "cmd": .control, "command": .control,
                "alt": .option, "option": .option,        // XK_Alt_L
                "shift": .shift,
                "ctrl": .control, "control": .control,
                "super": .command, "win": .command,       // XK_Super_L
            ]
        }
    }

    private nonisolated(unsafe) static let mouseButtons: [String: VNCMouseButton] = [
        "left": .left, "right": .right,
        "middle": .middle, "center": .middle,
    ]
}

public enum PlatformKeymapError: Error, LocalizedError {
    case unknownKey(String)
    case unknownButton(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key): "Unknown key: '\(key)'"
        case .unknownButton(let button): "Unknown mouse button: '\(button)'"
        }
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter PlatformKeymapTests
```

Expected: All 27 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GUIVisionVMDriver/Input/PlatformKeymap.swift Tests/GUIVisionVMDriverTests/Input/PlatformKeymapTests.swift
git commit -m "feat: platform-aware keysym mapping for VNC input"
```

---

### Task 8: VNC Input

**Files:**
- Create: `Sources/GUIVisionVMDriver/Input/VNCInput.swift`
- Create: `Tests/GUIVisionVMDriverTests/Input/VNCInputTests.swift`

VNCInput methods require a `VNCConnection` to send events. For unit testing, we test the resolution/decomposition logic (which doesn't need a connection) and verify the API compiles. Integration tests against a real VNC server are separate (Task 14).

- [ ] **Step 1: Write failing tests**

Create `Tests/GUIVisionVMDriverTests/Input/VNCInputTests.swift`:

```swift
import Testing
import RoyalVNCKit
@testable import GUIVisionVMDriver

@Suite("VNCInput")
struct VNCInputTests {

    // MARK: - Shifted character detection

    @Test func identifiesShiftedSymbols() {
        // These characters need Shift on a US keyboard
        let shifted: [Character] = ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")",
                                     "~", "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?"]
        for char in shifted {
            #expect(PlatformKeymap.shiftedCharToBase[char] != nil, "Expected \(char) to be shifted")
        }
    }

    @Test func unshiftedSymbolsNotInMap() {
        let unshifted: [Character] = ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"]
        for char in unshifted {
            #expect(PlatformKeymap.shiftedCharToBase[char] == nil, "Expected \(char) to NOT be shifted")
        }
    }

    // MARK: - Drag interpolation math

    @Test func dragInterpolatesLinearly() {
        // Test the interpolation logic used in drag().
        // 10 steps from (0,0) to (100,200):
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = UInt16(Double(0) + (Double(100) - Double(0)) * t)
            let y = UInt16(Double(0) + (Double(200) - Double(0)) * t)
            if i == steps {
                #expect(x == 100)
                #expect(y == 200)
            }
            if i == 5 {
                #expect(x == 50)
                #expect(y == 100)
            }
        }
    }

    // MARK: - API surface exists

    @Test func pressKeySignatureExists() {
        // Verify the function signature compiles.
        // We can't call it without a VNCConnection, but we verify it exists.
        let _: (String, [String], Platform?, VNCConnection) throws -> Void = VNCInput.pressKey
    }

    @Test func typeTextSignatureExists() {
        let _: (String, VNCConnection) -> Void = VNCInput.typeText
    }

    @Test func clickSignatureExists() {
        let _: (UInt16, UInt16, String, Int, VNCConnection) throws -> Void = VNCInput.click
    }

    @Test func mouseMoveSignatureExists() {
        let _: (UInt16, UInt16, VNCConnection) -> Void = VNCInput.mouseMove
    }

    @Test func scrollSignatureExists() {
        let _: (UInt16, UInt16, Int, Int, VNCConnection) -> Void = VNCInput.scroll
    }

    @Test func dragSignatureExists() {
        let _: (UInt16, UInt16, UInt16, UInt16, String, Int, VNCConnection) throws -> Void = VNCInput.drag
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter VNCInputTests 2>&1 | head -10
```

Expected: Compilation error — `VNCInput` not found.

- [ ] **Step 3: Implement VNCInput**

Create `Sources/GUIVisionVMDriver/Input/VNCInput.swift`:

```swift
import Foundation
@preconcurrency import RoyalVNCKit

/// VNC input: keyboard, mouse, and scroll operations.
///
/// Merges platform-aware modifier mapping from TestAnywareRedux with
/// raw keysym support and shifted character handling from TestAnyware.
public enum VNCInput {

    /// Whether to bypass RoyalVNCKit's ARD keysym remapping.
    /// Tart's Virtualization.framework VNC advertises ARD protocol but
    /// expects standard X11 keysyms. Set GUIVISION_VNC_ARD_REMAP=1 to
    /// re-enable the legacy ARD remapping.
    private static let useRawKeysyms: Bool = {
        ProcessInfo.processInfo.environment["GUIVISION_VNC_ARD_REMAP"] != "1"
    }()

    // MARK: - Keyboard

    /// Press and release a key with optional modifiers.
    public static func pressKey(
        _ key: String,
        modifiers: [String] = [],
        platform: Platform?,
        connection: VNCConnection
    ) throws {
        let keyCode = try PlatformKeymap.keyCode(for: key)
        let modCodes = PlatformKeymap.resolveModifiers(modifiers, platform: platform)

        if useRawKeysyms && !modCodes.isEmpty {
            for mod in modCodes { connection.keyDownRaw(mod.rawValue) }
            Thread.sleep(forTimeInterval: 0.05)
            connection.keyDownRaw(keyCode.rawValue)
            connection.keyUpRaw(keyCode.rawValue)
            Thread.sleep(forTimeInterval: 0.05)
            for mod in modCodes.reversed() { connection.keyUpRaw(mod.rawValue) }
        } else {
            for mod in modCodes { connection.keyDown(mod) }
            if !modCodes.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
            connection.keyDown(keyCode)
            connection.keyUp(keyCode)
            if !modCodes.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
            for mod in modCodes.reversed() { connection.keyUp(mod) }
        }
    }

    /// Type a string by sending individual character key events.
    /// Handles uppercase letters and shifted symbols (e.g. ! @ #).
    public static func typeText(_ text: String, connection: VNCConnection) {
        let shiftCode = VNCKeyCode.shift

        for char in text {
            if char.isUppercase, let lower = char.lowercased().first {
                let keyCodes = VNCKeyCode.withCharacter(lower)
                sendShifted(keyCodes: keyCodes, shiftCode: shiftCode, connection: connection)
            } else if let baseASCII = PlatformKeymap.shiftedCharToBase[char] {
                let keyCode = VNCKeyCode(asciiCharacter: baseASCII)
                sendShifted(keyCodes: [keyCode], shiftCode: shiftCode, connection: connection)
            } else {
                let keyCodes = VNCKeyCode.withCharacter(char)
                for code in keyCodes {
                    if useRawKeysyms {
                        connection.keyDownRaw(code.rawValue)
                        connection.keyUpRaw(code.rawValue)
                    } else {
                        connection.keyDown(code)
                        connection.keyUp(code)
                    }
                }
            }
        }
    }

    private static func sendShifted(keyCodes: [VNCKeyCode], shiftCode: VNCKeyCode, connection: VNCConnection) {
        if useRawKeysyms {
            connection.keyDownRaw(shiftCode.rawValue)
            Thread.sleep(forTimeInterval: 0.05)
            for code in keyCodes {
                connection.keyDownRaw(code.rawValue)
                connection.keyUpRaw(code.rawValue)
            }
            Thread.sleep(forTimeInterval: 0.05)
            connection.keyUpRaw(shiftCode.rawValue)
        } else {
            connection.keyDown(shiftCode)
            Thread.sleep(forTimeInterval: 0.05)
            for code in keyCodes {
                connection.keyDown(code)
                connection.keyUp(code)
            }
            Thread.sleep(forTimeInterval: 0.05)
            connection.keyUp(shiftCode)
        }
    }

    // MARK: - Mouse

    /// Move mouse pointer to absolute coordinates.
    public static func mouseMove(x: UInt16, y: UInt16, connection: VNCConnection) {
        connection.mouseMove(x: x, y: y)
    }

    /// Click at coordinates with optional button and count.
    public static func click(
        x: UInt16, y: UInt16,
        button: String = "left",
        count: Int = 1,
        connection: VNCConnection
    ) throws {
        let btn = try PlatformKeymap.mouseButton(for: button)
        for _ in 0..<count {
            connection.mouseButtonDown(btn, x: x, y: y)
            connection.mouseButtonUp(btn, x: x, y: y)
        }
    }

    /// Scroll at coordinates.
    public static func scroll(
        x: UInt16, y: UInt16,
        deltaX: Int, deltaY: Int,
        connection: VNCConnection
    ) {
        let components = PlatformKeymap.decomposeScroll(deltaX: deltaX, deltaY: deltaY)
        for component in components {
            connection.mouseWheel(component.direction, x: x, y: y, steps: component.steps)
        }
    }

    /// Drag from one point to another with interpolated steps.
    public static func drag(
        fromX: UInt16, fromY: UInt16,
        toX: UInt16, toY: UInt16,
        button: String = "left",
        steps: Int = 10,
        connection: VNCConnection
    ) throws {
        let btn = try PlatformKeymap.mouseButton(for: button)
        connection.mouseButtonDown(btn, x: fromX, y: fromY)

        let effectiveSteps = max(steps, 1)
        for i in 1...effectiveSteps {
            let t = Double(i) / Double(effectiveSteps)
            let x = UInt16(Double(fromX) + (Double(toX) - Double(fromX)) * t)
            let y = UInt16(Double(fromY) + (Double(toY) - Double(fromY)) * t)
            connection.mouseMove(x: x, y: y)
        }

        connection.mouseButtonUp(btn, x: toX, y: toY)
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter VNCInputTests
```

Expected: All 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GUIVisionVMDriver/Input/VNCInput.swift Tests/GUIVisionVMDriverTests/Input/VNCInputTests.swift
git commit -m "feat: VNC input with platform-aware modifiers, raw keysyms, shifted chars"
```

---

## Phase 4: SSH

### Task 9: SSH Client

**Files:**
- Create: `Sources/GUIVisionVMDriver/SSH/SSHClient.swift`
- Create: `Tests/GUIVisionVMDriverTests/SSH/SSHClientTests.swift`

The SSH client uses OpenSSH's ControlMaster for persistent connections. Commands are executed by shelling out to `ssh` and `scp` with appropriate flags. This avoids adding a heavy SSH library dependency while providing persistent, multiplexed connections.

- [ ] **Step 1: Write failing tests**

Create `Tests/GUIVisionVMDriverTests/SSH/SSHClientTests.swift`:

```swift
import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("SSHClient")
struct SSHClientTests {

    // MARK: - Initialization

    @Test func initFromSSHSpec() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin", key: "~/.ssh/id_ed25519")
        let client = SSHClient(spec: spec)
        #expect(client.host == "myhost")
        #expect(client.port == 2222)
        #expect(client.user == "admin")
    }

    @Test func initFromConnectionSpec() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", ssh: "root@10.0.0.1:2222")
        let client = try SSHClient(connectionSpec: spec)
        #expect(client.host == "10.0.0.1")
        #expect(client.user == "root")
        #expect(client.port == 2222)
    }

    @Test func initFailsWithoutSSHSpec() {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost"))
        #expect(throws: SSHClientError.self) {
            try SSHClient(connectionSpec: spec)
        }
    }

    // MARK: - Control path

    @Test func controlPathIsUnique() {
        let spec1 = SSHSpec(host: "host1", user: "user1")
        let spec2 = SSHSpec(host: "host2", user: "user2")
        let client1 = SSHClient(spec: spec1)
        let client2 = SSHClient(spec: spec2)
        #expect(client1.controlPath != client2.controlPath)
    }

    @Test func controlPathIsDeterministic() {
        let spec = SSHSpec(host: "myhost", port: 22, user: "admin")
        let client1 = SSHClient(spec: spec)
        let client2 = SSHClient(spec: spec)
        #expect(client1.controlPath == client2.controlPath)
    }

    // MARK: - Command building

    @Test func buildsSSHCommandWithKey() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin", key: "~/.ssh/id_ed25519")
        let client = SSHClient(spec: spec)
        let args = client.sshArguments(for: "echo hello")
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.contains("-i"))
        #expect(args.contains("~/.ssh/id_ed25519"))
        #expect(args.contains("admin@myhost"))
        #expect(args.last == "echo hello")
    }

    @Test func buildsSSHCommandWithoutKey() {
        let spec = SSHSpec(host: "myhost", user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.sshArguments(for: "ls")
        #expect(!args.contains("-i"))
        #expect(args.contains("admin@myhost"))
    }

    // MARK: - SCP argument building

    @Test func buildsSCPUploadArgs() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.scpUploadArguments(localPath: "/tmp/file.txt", remotePath: "/home/admin/file.txt")
        #expect(args.contains("-P"))
        #expect(args.contains("2222"))
        #expect(args.contains("/tmp/file.txt"))
        #expect(args.last == "admin@myhost:/home/admin/file.txt")
    }

    @Test func buildsSCPDownloadArgs() {
        let spec = SSHSpec(host: "myhost", user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.scpDownloadArguments(remotePath: "/var/log/app.log", localPath: "/tmp/app.log")
        #expect(args.contains("admin@myhost:/var/log/app.log"))
        #expect(args.last == "/tmp/app.log")
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter SSHClientTests 2>&1 | head -10
```

Expected: Compilation error — `SSHClient` not found.

- [ ] **Step 3: Implement SSHClient**

Create `Sources/GUIVisionVMDriver/SSH/SSHClient.swift`:

```swift
import Foundation

/// Result of an SSH command execution.
public struct SSHResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

/// SSH client using OpenSSH ControlMaster for persistent connections.
///
/// Manages multiplexed SSH connections via ControlPath sockets.
/// Commands are executed by spawning `ssh` processes that reuse
/// the master connection, avoiding per-command authentication overhead.
public final class SSHClient: Sendable {
    public let host: String
    public let port: Int
    public let user: String
    private let key: String?
    private let password: String?

    /// ControlMaster socket path, deterministic for a given host+port+user.
    public let controlPath: String

    public init(spec: SSHSpec) {
        self.host = spec.host
        self.port = spec.port
        self.user = spec.user
        self.key = spec.key
        self.password = spec.password
        self.controlPath = Self.controlSocketPath(host: spec.host, port: spec.port, user: spec.user)
    }

    public convenience init(connectionSpec: ConnectionSpec) throws {
        guard let ssh = connectionSpec.ssh else {
            throw SSHClientError.noSSHSpec
        }
        self.init(spec: ssh)
    }

    // MARK: - Command Execution

    /// Execute a command on the remote host.
    @discardableResult
    public func exec(_ command: String, timeout: TimeInterval = 30) throws -> SSHResult {
        let args = sshArguments(for: command)
        return try runProcess("/usr/bin/ssh", arguments: args, timeout: timeout)
    }

    // MARK: - File Transfer

    /// Upload a local file to the remote host.
    public func upload(localPath: String, remotePath: String, timeout: TimeInterval = 60) throws -> SSHResult {
        let args = scpUploadArguments(localPath: localPath, remotePath: remotePath)
        return try runProcess("/usr/bin/scp", arguments: args, timeout: timeout)
    }

    /// Download a file from the remote host.
    public func download(remotePath: String, localPath: String, timeout: TimeInterval = 60) throws -> SSHResult {
        let args = scpDownloadArguments(remotePath: remotePath, localPath: localPath)
        return try runProcess("/usr/bin/scp", arguments: args, timeout: timeout)
    }

    // MARK: - Connection Management

    /// Establish the ControlMaster connection.
    public func connect(timeout: TimeInterval = 10) throws {
        let args = baseSSHArguments() + [
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=300",
            "-N", "-f",  // go to background, no command
            "\(user)@\(host)",
        ]
        let result = try runProcess("/usr/bin/ssh", arguments: args, timeout: timeout)
        if !result.succeeded {
            throw SSHClientError.connectionFailed(result.stderr)
        }
    }

    /// Tear down the ControlMaster connection.
    public func disconnect() {
        let args = baseSSHArguments() + [
            "-O", "exit",
            "\(user)@\(host)",
        ]
        _ = try? runProcess("/usr/bin/ssh", arguments: args, timeout: 5)
    }

    /// Check if the ControlMaster socket exists.
    public var isConnected: Bool {
        FileManager.default.fileExists(atPath: controlPath)
    }

    // MARK: - Argument Building (internal for testing)

    func sshArguments(for command: String) -> [String] {
        var args = baseSSHArguments()
        args += ["-o", "ControlMaster=auto"]
        args += ["\(user)@\(host)", command]
        return args
    }

    func scpUploadArguments(localPath: String, remotePath: String) -> [String] {
        var args = baseSCPArguments()
        args += [localPath, "\(user)@\(host):\(remotePath)"]
        return args
    }

    func scpDownloadArguments(remotePath: String, localPath: String) -> [String] {
        var args = baseSCPArguments()
        args += ["\(user)@\(host):\(remotePath)", localPath]
        return args
    }

    // MARK: - Private

    private func baseSSHArguments() -> [String] {
        var args: [String] = []
        args += ["-o", "ControlPath=\(controlPath)"]
        args += ["-o", "StrictHostKeyChecking=no"]
        args += ["-o", "UserKnownHostsFile=/dev/null"]
        args += ["-o", "LogLevel=ERROR"]
        args += ["-p", "\(port)"]
        if let key {
            args += ["-i", key]
        }
        return args
    }

    private func baseSCPArguments() -> [String] {
        var args: [String] = []
        args += ["-o", "ControlPath=\(controlPath)"]
        args += ["-o", "ControlMaster=auto"]
        args += ["-o", "StrictHostKeyChecking=no"]
        args += ["-o", "UserKnownHostsFile=/dev/null"]
        args += ["-o", "LogLevel=ERROR"]
        args += ["-P", "\(port)"]
        if let key {
            args += ["-i", key]
        }
        return args
    }

    private static func controlSocketPath(host: String, port: Int, user: String) -> String {
        let dir = NSTemporaryDirectory() + "guivision-ssh"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(user)@\(host):\(port)"
    }

    private func runProcess(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw SSHClientError.launchFailed(error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return SSHResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

// MARK: - Errors

public enum SSHClientError: Error, LocalizedError {
    case noSSHSpec
    case connectionFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSSHSpec:
            "ConnectionSpec has no SSH configuration"
        case .connectionFailed(let detail):
            "SSH connection failed: \(detail)"
        case .launchFailed(let detail):
            "Failed to launch SSH process: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter SSHClientTests
```

Expected: All 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GUIVisionVMDriver/SSH/SSHClient.swift Tests/GUIVisionVMDriverTests/SSH/SSHClientTests.swift
git commit -m "feat: SSH client with ControlMaster persistent connections and SCP"
```

---

## Phase 5: Streaming Capture

### Task 10: Streaming Capture

**Files:**
- Create: `Sources/GUIVisionVMDriver/Capture/StreamingCapture.swift`
- Create: `Tests/GUIVisionVMDriverTests/Capture/StreamingCaptureTests.swift`
- Modify: `Package.swift` (add AVFoundation linker setting)

- [ ] **Step 1: Update Package.swift to link AVFoundation**

In `Package.swift`, update the library target's linkerSettings:

```swift
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
```

- [ ] **Step 2: Write failing tests**

Create `Tests/GUIVisionVMDriverTests/Capture/StreamingCaptureTests.swift`:

```swift
import Testing
import CoreGraphics
import Foundation
@testable import GUIVisionVMDriver

@Suite("StreamingCapture")
struct StreamingCaptureTests {

    @Test func initWithDefaults() {
        let config = StreamingCaptureConfig(width: 1920, height: 1080)
        #expect(config.width == 1920)
        #expect(config.height == 1080)
        #expect(config.fps == 30)
        #expect(config.codec == .h264)
    }

    @Test func initWithCustomFPS() {
        let config = StreamingCaptureConfig(width: 1280, height: 720, fps: 60)
        #expect(config.fps == 60)
    }

    @Test func stateStartsIdle() async {
        let capture = StreamingCapture()
        let state = await capture.state
        #expect(state == .idle)
    }

    @Test func recordsToFile() async throws {
        let outputPath = NSTemporaryDirectory() + "test_recording_\(UUID().uuidString).mp4"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let config = StreamingCaptureConfig(width: 100, height: 100, fps: 10, codec: .h264)
        let capture = StreamingCapture()

        try await capture.start(outputPath: outputPath, config: config)
        #expect(await capture.state == .recording)

        // Feed a few synthetic frames
        let image = try createTestImage(width: 100, height: 100)
        for _ in 0..<5 {
            try await capture.appendFrame(image)
            try await Task.sleep(for: .milliseconds(100))
        }

        try await capture.stop()
        #expect(await capture.state == .idle)

        // Verify file was created and has content
        let fileExists = FileManager.default.fileExists(atPath: outputPath)
        #expect(fileExists)
        let attrs = try FileManager.default.attributesOfItem(atPath: outputPath)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)
    }

    @Test func stopWhenIdleThrows() async {
        let capture = StreamingCapture()
        do {
            try await capture.stop()
            Issue.record("Expected error")
        } catch {
            #expect(error is StreamingCaptureError)
        }
    }

    @Test func doubleStartThrows() async throws {
        let path1 = NSTemporaryDirectory() + "test1_\(UUID().uuidString).mp4"
        let path2 = NSTemporaryDirectory() + "test2_\(UUID().uuidString).mp4"
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        let config = StreamingCaptureConfig(width: 100, height: 100, fps: 10)
        let capture = StreamingCapture()
        try await capture.start(outputPath: path1, config: config)

        do {
            try await capture.start(outputPath: path2, config: config)
            Issue.record("Expected error")
        } catch {
            #expect(error is StreamingCaptureError)
        }

        try await capture.stop()
    }

    // MARK: - Helpers

    private func createTestImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextFailed }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestImageError.imageFailed }
        return image
    }
}

private enum TestImageError: Error { case contextFailed, imageFailed }
```

- [ ] **Step 3: Run tests — verify they fail**

```bash
swift test --filter StreamingCaptureTests 2>&1 | head -10
```

Expected: Compilation error — `StreamingCapture` not found.

- [ ] **Step 4: Implement StreamingCapture**

Create `Sources/GUIVisionVMDriver/Capture/StreamingCapture.swift`:

```swift
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Configuration for streaming video capture.
public struct StreamingCaptureConfig: Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: VideoCodec

    public init(width: Int, height: Int, fps: Int = 30, codec: VideoCodec = .h264) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
    }

    public enum VideoCodec: Sendable {
        case h264
        case hevc
    }
}

/// Records a stream of CGImage frames to a video file.
public actor StreamingCapture {
    public enum State: Sendable { case idle, recording }

    public private(set) var state: State = .idle

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameCount: Int = 0
    private var fps: Int = 30
    private var config: StreamingCaptureConfig?

    public init() {}

    /// Start recording to the given file path.
    public func start(outputPath: String, config: StreamingCaptureConfig) throws {
        guard state == .idle else {
            throw StreamingCaptureError.alreadyRecording
        }

        let url = URL(fileURLWithPath: outputPath)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let avCodec: AVVideoCodecType = config.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor
        self.frameCount = 0
        self.fps = config.fps
        self.config = config
        self.state = .recording
    }

    /// Append a frame to the recording.
    public func appendFrame(_ image: CGImage) throws {
        guard state == .recording,
              let adaptor = pixelBufferAdaptor,
              let input = videoInput else {
            throw StreamingCaptureError.notRecording
        }

        guard input.isReadyForMoreMediaData else { return }

        guard let pool = adaptor.pixelBufferPool else {
            throw StreamingCaptureError.pixelBufferPoolUnavailable
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw StreamingCaptureError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw StreamingCaptureError.pixelBufferCreationFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw StreamingCaptureError.pixelBufferCreationFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let presentationTime = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps))
        adaptor.append(buffer, withPresentationTime: presentationTime)
        frameCount += 1
    }

    /// Stop recording and finalize the video file.
    public func stop() async throws {
        guard state == .recording, let writer = assetWriter else {
            throw StreamingCaptureError.notRecording
        }

        videoInput?.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        self.assetWriter = nil
        self.videoInput = nil
        self.pixelBufferAdaptor = nil
        self.config = nil
        self.state = .idle
    }
}

public enum StreamingCaptureError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Already recording"
        case .notRecording: "Not currently recording"
        case .pixelBufferPoolUnavailable: "Pixel buffer pool not available"
        case .pixelBufferCreationFailed: "Failed to create pixel buffer"
        }
    }
}
```

- [ ] **Step 5: Run tests — verify they pass**

```bash
swift test --filter StreamingCaptureTests
```

Expected: All 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/GUIVisionVMDriver/Capture/StreamingCapture.swift Tests/GUIVisionVMDriverTests/Capture/StreamingCaptureTests.swift
git commit -m "feat: streaming capture with AVAssetWriter video recording"
```

---

## Phase 6: CLI

### Task 11: CLI — Screenshot Command

**Files:**
- Modify: `Sources/guivision/GUIVisionCLI.swift`
- Create: `Sources/guivision/ScreenshotCommand.swift`

- [ ] **Step 1: Update root CLI with shared connection options**

Replace `Sources/guivision/GUIVisionCLI.swift`:

```swift
import ArgumentParser
import GUIVisionVMDriver

@main
struct GUIVisionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision",
        abstract: "VNC + SSH driver for virtual machine automation",
        version: "0.1.0",
        subcommands: [
            ScreenshotCommand.self,
        ]
    )
}

/// Shared connection options used by all subcommands.
struct ConnectionOptions: ParsableArguments {
    @Option(name: .long, help: "Path to connection spec JSON file")
    var connect: String?

    @Option(name: .long, help: "VNC endpoint (host:port)")
    var vnc: String?

    @Option(name: .long, help: "SSH endpoint (user@host[:port])")
    var ssh: String?

    @Option(name: .long, help: "Target platform (macos, windows, linux)")
    var platform: String?

    func resolve() throws -> ConnectionSpec {
        if let connectPath = connect {
            return try ConnectionSpec.load(from: connectPath)
        } else if let vncEndpoint = vnc {
            return try ConnectionSpec.from(vnc: vncEndpoint, ssh: ssh, platform: platform)
        } else {
            throw ValidationError("Either --connect or --vnc is required")
        }
    }
}
```

- [ ] **Step 2: Implement ScreenshotCommand**

Create `Sources/guivision/ScreenshotCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the VNC server"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .shortAndLong, help: "Output file path (default: screenshot.png)")
    var output: String = "screenshot.png"

    @Option(name: .long, help: "Crop region as x,y,width,height")
    var region: String?

    mutating func run() async throws {
        let spec = try connection.resolve()

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        let cropRegion: CGRect?
        if let regionStr = region {
            cropRegion = try parseRegion(regionStr)
        } else {
            cropRegion = nil
        }

        let pngData = try await capture.screenshot(region: cropRegion)
        let url = URL(fileURLWithPath: output)
        try pngData.write(to: url)
        print("Screenshot saved to \(output) (\(pngData.count) bytes)")
    }

    private func parseRegion(_ str: String) throws -> CGRect {
        let parts = str.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else {
            throw ValidationError("Region must be x,y,width,height (e.g. 0,0,800,600)")
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 4: Commit**

```bash
git add Sources/guivision/
git commit -m "feat: CLI with screenshot command and shared connection options"
```

---

### Task 12: CLI — Input Commands

**Files:**
- Create: `Sources/guivision/InputCommand.swift`
- Modify: `Sources/guivision/GUIVisionCLI.swift` (add to subcommands)

- [ ] **Step 1: Implement InputCommand with subcommands**

Create `Sources/guivision/InputCommand.swift`:

```swift
import ArgumentParser
import GUIVisionVMDriver

struct InputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Send keyboard and mouse input",
        subcommands: [
            KeyPressCommand.self,
            TypeCommand.self,
            ClickCommand.self,
            MoveCommand.self,
            ScrollCommand.self,
            DragCommand.self,
        ]
    )
}

struct KeyPressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a key")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Key name (e.g. return, tab, a, f1)")
    var key: String

    @Option(name: .shortAndLong, help: "Modifier keys (comma-separated: cmd,shift,alt,ctrl)")
    var modifiers: String?

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        let mods = modifiers?.split(separator: ",").map(String.init) ?? []
        try await capture.withConnection { conn in
            try VNCInput.pressKey(key, modifiers: mods, platform: spec.platform, connection: conn)
        }
        print("Key pressed: \(key)\(mods.isEmpty ? "" : " + \(mods.joined(separator: "+"))")")
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Text to type")
    var text: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.typeText(text, connection: conn)
        }
        print("Typed: \(text)")
    }
}

struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click at coordinates")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .shortAndLong, help: "Mouse button (left, right, middle)")
    var button: String = "left"

    @Option(name: .shortAndLong, help: "Click count")
    var count: Int = 1

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.click(x: UInt16(x), y: UInt16(y), button: button, count: count, connection: conn)
        }
        print("Clicked at (\(x), \(y)) button=\(button) count=\(count)")
    }
}

struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move mouse")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: UInt16(x), y: UInt16(y), connection: conn)
        }
        print("Mouse moved to (\(x), \(y))")
    }
}

struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll at coordinates")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .long, help: "Horizontal scroll amount (negative=left)")
    var dx: Int = 0

    @Option(name: .long, help: "Vertical scroll amount (negative=up)")
    var dy: Int = 0

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.scroll(x: UInt16(x), y: UInt16(y), deltaX: dx, deltaY: dy, connection: conn)
        }
        print("Scrolled at (\(x), \(y)) dx=\(dx) dy=\(dy)")
    }
}

struct DragCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drag", abstract: "Drag from one point to another")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Start X")
    var fromX: Int

    @Argument(help: "Start Y")
    var fromY: Int

    @Argument(help: "End X")
    var toX: Int

    @Argument(help: "End Y")
    var toY: Int

    @Option(name: .shortAndLong, help: "Mouse button")
    var button: String = "left"

    @Option(name: .shortAndLong, help: "Number of interpolation steps")
    var steps: Int = 10

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.drag(fromX: UInt16(fromX), fromY: UInt16(fromY),
                              toX: UInt16(toX), toY: UInt16(toY),
                              button: button, steps: steps, connection: conn)
        }
        print("Dragged from (\(fromX),\(fromY)) to (\(toX),\(toY))")
    }
}
```

- [ ] **Step 2: Register InputCommand in GUIVisionCLI**

In `Sources/guivision/GUIVisionCLI.swift`, update the subcommands array:

```swift
        subcommands: [
            ScreenshotCommand.self,
            InputCommand.self,
        ]
```

- [ ] **Step 3: Verify it builds**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 4: Commit**

```bash
git add Sources/guivision/
git commit -m "feat: CLI input commands (key, type, click, move, scroll, drag)"
```

---

### Task 13: CLI — SSH and Record Commands

**Files:**
- Create: `Sources/guivision/SSHCommand.swift`
- Create: `Sources/guivision/RecordCommand.swift`
- Modify: `Sources/guivision/GUIVisionCLI.swift` (add to subcommands)

- [ ] **Step 1: Implement SSHCommand**

Create `Sources/guivision/SSHCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct SSHCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Execute commands and transfer files over SSH",
        subcommands: [
            ExecCommand.self,
            UploadCommand.self,
            DownloadCommand.self,
        ]
    )
}

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a remote command")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Command to execute")
    var command: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try SSHClient(connectionSpec: spec)
        let result = try client.exec(command)
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        if !result.succeeded {
            throw ExitCode(result.exitCode)
        }
    }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a file")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Local file path")
    var localPath: String

    @Argument(help: "Remote file path")
    var remotePath: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try SSHClient(connectionSpec: spec)
        let result = try client.upload(localPath: localPath, remotePath: remotePath)
        if !result.succeeded {
            throw ValidationError("Upload failed: \(result.stderr)")
        }
        print("Uploaded \(localPath) → \(remotePath)")
    }
}

struct DownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "download", abstract: "Download a file")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Remote file path")
    var remotePath: String

    @Argument(help: "Local file path")
    var localPath: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try SSHClient(connectionSpec: spec)
        let result = try client.download(remotePath: remotePath, localPath: localPath)
        if !result.succeeded {
            throw ValidationError("Download failed: \(result.stderr)")
        }
        print("Downloaded \(remotePath) → \(localPath)")
    }
}
```

- [ ] **Step 2: Implement RecordCommand**

Create `Sources/guivision/RecordCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record VNC screen to a video file"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "recording.mp4"

    @Option(name: .long, help: "Frames per second")
    var fps: Int = 30

    @Option(name: .long, help: "Duration in seconds (0 = until Ctrl+C)")
    var duration: Int = 0

    @Option(name: .long, help: "Crop region as x,y,width,height")
    var region: String?

    mutating func run() async throws {
        let spec = try connection.resolve()

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()

        guard let screenSize = await capture.screenSize() else {
            throw ValidationError("Could not determine screen size")
        }

        let cropRegion: CGRect?
        if let regionStr = region {
            let parts = regionStr.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                throw ValidationError("Region must be x,y,width,height")
            }
            cropRegion = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else {
            cropRegion = nil
        }

        let recordWidth = Int(cropRegion?.width ?? screenSize.width)
        let recordHeight = Int(cropRegion?.height ?? screenSize.height)

        let config = StreamingCaptureConfig(width: recordWidth, height: recordHeight, fps: fps)
        let recorder = StreamingCapture()
        try await recorder.start(outputPath: output, config: config)

        print("Recording to \(output) at \(fps) fps (\(recordWidth)x\(recordHeight))...")
        if duration > 0 {
            print("Duration: \(duration)s")
        } else {
            print("Press Ctrl+C to stop")
        }

        let interval = Duration.milliseconds(1000 / fps)
        let deadline = duration > 0 ? ContinuousClock.now + .seconds(duration) : ContinuousClock.Instant.distantFuture

        while ContinuousClock.now < deadline {
            if let image = try? await capture.captureImage(region: cropRegion) {
                try? await recorder.appendFrame(image)
            }
            try await Task.sleep(for: interval)
        }

        try await recorder.stop()
        await capture.disconnect()
        print("Recording saved to \(output)")
    }
}
```

- [ ] **Step 3: Register commands in GUIVisionCLI**

In `Sources/guivision/GUIVisionCLI.swift`, update:

```swift
        subcommands: [
            ScreenshotCommand.self,
            InputCommand.self,
            SSHCommand.self,
            RecordCommand.self,
        ]
```

- [ ] **Step 4: Verify it builds**

```bash
swift build
```

Expected: Builds successfully.

- [ ] **Step 5: Verify CLI help output**

```bash
swift run guivision --help
swift run guivision input --help
swift run guivision ssh --help
```

Expected: Help text shows all subcommands and options.

- [ ] **Step 6: Commit**

```bash
git add Sources/guivision/
git commit -m "feat: CLI ssh and record commands"
```

---

## Phase 7: VM Test Infrastructure

### Task 14: VMManager — tart CLI Wrapper

**Files:**
- Create: `Tests/TestSupport/VMManager.swift`
- Create: `Tests/GUIVisionVMDriverTests/VMManagerTests.swift`

VMManager wraps the `tart` CLI for VM lifecycle management. It handles cloning, starting (with VNC), stopping, and parsing VNC URLs from tart's output. This is a low-level building block — VMTestEnvironment (Task 15) adds the lazy lifecycle on top.

- [ ] **Step 1: Write failing tests for VMManager**

Create `Tests/GUIVisionVMDriverTests/VMManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TestSupport

@Suite("VMManager")
struct VMManagerTests {

    // MARK: - Argument building

    @Test func buildsTartRunArgs() {
        let args = VMManager.tartArguments(for: .run, vm: "my-vm")
        #expect(args == ["run", "my-vm", "--no-graphics", "--vnc-experimental"])
    }

    @Test func buildsTartCloneArgs() {
        let args = VMManager.tartArguments(for: .clone, vm: "base-image", destination: "my-vm")
        #expect(args == ["clone", "base-image", "my-vm"])
    }

    @Test func buildsTartStopArgs() {
        let args = VMManager.tartArguments(for: .stop, vm: "my-vm")
        #expect(args == ["stop", "my-vm"])
    }

    @Test func buildsTartDeleteArgs() {
        let args = VMManager.tartArguments(for: .delete, vm: "my-vm")
        #expect(args == ["delete", "my-vm"])
    }

    @Test func buildsTartListArgs() {
        let args = VMManager.tartArguments(for: .list, vm: "")
        #expect(args == ["list", "--format", "json"])
    }

    // MARK: - VNC URL parsing

    @Test func parsesVNCURLWithPasswordAndPort() {
        let output = "vnc://:s3cret@localhost:5901\n"
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 5901)
        #expect(endpoint?.password == "s3cret")
    }

    @Test func parsesVNCURLWithoutPassword() {
        let output = "vnc://localhost:5900\n"
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 5900)
        #expect(endpoint?.password == "")
    }

    @Test func parsesVNCURLFromMultilineOutput() {
        let output = """
        Waiting for VM to boot...
        vnc://:abc123@127.0.0.1:59432...
        Some other output
        """
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.password == "abc123")
        #expect(endpoint?.port == 59432)
    }

    @Test func returnsNilForNoVNCURL() {
        let output = "No VNC URL here\n"
        #expect(VMManager.parseVNCURL(from: output) == nil)
    }

    // MARK: - VM existence check (JSON list parsing)

    @Test func detectsVMInListOutput() {
        let json = """
        [{"Name":"guivision-test","State":"stopped","Disk":10737418240},
         {"Name":"other-vm","State":"running","Disk":10737418240}]
        """
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: json) == true)
    }

    @Test func detectsAbsentVMInListOutput() {
        let json = """
        [{"Name":"other-vm","State":"stopped","Disk":10737418240}]
        """
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: json) == false)
    }

    @Test func handlesEmptyList() {
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: "[]") == false)
    }

    @Test func detectsVMStateFromList() {
        let json = """
        [{"Name":"guivision-test","State":"running","Disk":10737418240}]
        """
        #expect(VMManager.vmStateInList(vmName: "guivision-test", listOutput: json) == "running")
    }

    @Test func returnsNilStateForAbsentVM() {
        let json = """
        [{"Name":"other-vm","State":"stopped","Disk":10737418240}]
        """
        #expect(VMManager.vmStateInList(vmName: "guivision-test", listOutput: json) == nil)
    }
}
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
swift test --filter VMManagerTests 2>&1 | head -10
```

Expected: Compilation error — `VMManager` not found or is an empty placeholder.

- [ ] **Step 3: Implement VMManager**

Replace `Tests/TestSupport/TestSupport.swift` (the placeholder) with the following, or create `Tests/TestSupport/VMManager.swift`:

Create `Tests/TestSupport/VMManager.swift`:

```swift
import Foundation
import GUIVisionVMDriver

/// VNC endpoint returned by VMManager after starting a VM.
public struct VNCEndpoint: Sendable {
    public let host: String
    public let port: Int
    public let password: String

    public init(host: String, port: Int, password: String) {
        self.host = host
        self.port = port
        self.password = password
    }

    /// Convert to a VNCSpec for use with VNCCapture.
    public var vncSpec: VNCSpec {
        VNCSpec(host: host, port: port, password: password.isEmpty ? nil : password)
    }

    /// Convert to a full ConnectionSpec.
    public var connectionSpec: ConnectionSpec {
        ConnectionSpec(vnc: vncSpec, platform: .macos)
    }
}

/// Wraps the `tart` CLI for VM lifecycle management in tests.
///
/// This is the low-level layer. Use `VMTestEnvironment` for the lazy
/// create-once/start-stop-per-suite lifecycle.
public final class VMManager: Sendable {
    public enum Command {
        case run, clone, stop, delete, list
    }

    private let tartPath: String

    public init(tartPath: String = "/opt/homebrew/bin/tart") {
        self.tartPath = tartPath
    }

    // MARK: - Argument Building (public for testing)

    /// Build tart CLI arguments for a given command.
    public static func tartArguments(for command: Command, vm: String, destination: String? = nil) -> [String] {
        switch command {
        case .run:
            return ["run", vm, "--no-graphics", "--vnc-experimental"]
        case .clone:
            guard let dest = destination else { return ["clone", vm] }
            return ["clone", vm, dest]
        case .stop:
            return ["stop", vm]
        case .delete:
            return ["delete", vm]
        case .list:
            return ["list", "--format", "json"]
        }
    }

    // MARK: - Output Parsing (public for testing)

    /// Parse VNC URL from tart's stdout (e.g. "vnc://:password@localhost:5901").
    public static func parseVNCURL(from output: String) -> VNCEndpoint? {
        guard let range = output.range(of: "vnc://[^\\s]+", options: .regularExpression) else {
            return nil
        }
        // tart appends "..." to the URL while waiting; strip it.
        let urlString = String(output[range]).replacingOccurrences(of: "...", with: "")
        guard let url = URL(string: urlString) else { return nil }
        let password = url.password ?? ""
        let host = url.host ?? "localhost"
        let port = url.port ?? 5900
        return VNCEndpoint(host: host, port: port, password: password)
    }

    /// Check if a VM exists in `tart list --format json` output.
    public static func vmExistsInList(vmName: String, listOutput: String) -> Bool {
        vmStateInList(vmName: vmName, listOutput: listOutput) != nil
    }

    /// Get the state of a VM from `tart list --format json` output.
    /// Returns "running", "stopped", or nil if not found.
    public static func vmStateInList(vmName: String, listOutput: String) -> String? {
        guard let data = listOutput.data(using: .utf8),
              let vms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for vm in vms {
            if let name = vm["Name"] as? String, name == vmName {
                return vm["State"] as? String
            }
        }
        return nil
    }

    // MARK: - VM Operations

    /// Check if a VM exists.
    public func vmExists(_ name: String) throws -> Bool {
        let output = try runTart(Self.tartArguments(for: .list, vm: ""))
        return Self.vmExistsInList(vmName: name, listOutput: output)
    }

    /// Get VM state ("running", "stopped", or nil).
    public func vmState(_ name: String) throws -> String? {
        let output = try runTart(Self.tartArguments(for: .list, vm: ""))
        return Self.vmStateInList(vmName: name, listOutput: output)
    }

    /// Clone a base VM image.
    public func clone(from base: String, to name: String) throws {
        try runTart(Self.tartArguments(for: .clone, vm: base, destination: name))
    }

    /// Start a VM with VNC. Blocks until VNC URL appears in tart's output.
    /// Returns the VNC endpoint. The tart process runs in the background.
    public func start(vm: String, timeout: TimeInterval = 120) throws -> (process: Process, endpoint: VNCEndpoint) {
        let safeName = vm.replacingOccurrences(of: "/", with: "_")
        let outputFile = NSTemporaryDirectory() + "guivision-vnc-\(ProcessInfo.processInfo.processIdentifier)-\(safeName).txt"
        FileManager.default.createFile(atPath: outputFile, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tartPath)
        process.arguments = Self.tartArguments(for: .run, vm: vm)
        let outHandle = FileHandle(forWritingAtPath: outputFile)!
        process.standardOutput = outHandle
        process.standardError = outHandle
        try process.run()

        // Poll for VNC URL in tart's output.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            if let content = try? String(contentsOfFile: outputFile, encoding: .utf8),
               let endpoint = Self.parseVNCURL(from: content) {
                try? FileManager.default.removeItem(atPath: outputFile)
                return (process, endpoint)
            }
        }
        process.terminate()
        try? FileManager.default.removeItem(atPath: outputFile)
        throw VMManagerError.timeout("VM '\(vm)' did not produce a VNC URL within \(Int(timeout))s")
    }

    /// Stop a running VM.
    public func stop(vm: String) throws {
        try runTart(Self.tartArguments(for: .stop, vm: vm))
    }

    /// Delete a VM.
    public func delete(vm: String) throws {
        try runTart(Self.tartArguments(for: .delete, vm: vm))
    }

    // MARK: - Private

    @discardableResult
    private func runTart(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tartPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw VMManagerError.commandFailed(
                "tart \(arguments.joined(separator: " "))", output
            )
        }
        return output
    }
}

public enum VMManagerError: Error, LocalizedError {
    case commandFailed(String, String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let output):
            "Command failed: \(cmd)\n\(output)"
        case .timeout(let msg):
            msg
        }
    }
}
```

Update `Tests/TestSupport/TestSupport.swift` to remove the placeholder comment:

```swift
// TestSupport — shared test infrastructure for VM-backed integration tests.
// VMManager: tart CLI wrapper
// VMTestEnvironment: lazy VM lifecycle (create once, start/stop per suite)
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
swift test --filter VMManagerTests
```

Expected: All 14 tests pass (pure parsing/argument tests, no tart required).

- [ ] **Step 5: Commit**

```bash
git add Tests/TestSupport/VMManager.swift Tests/TestSupport/TestSupport.swift Tests/GUIVisionVMDriverTests/VMManagerTests.swift
git commit -m "feat: VMManager — tart CLI wrapper with VNC URL parsing"
```

---

### Task 15: VMTestEnvironment — Lazy VM Lifecycle

**Files:**
- Create: `Tests/TestSupport/VMTestEnvironment.swift`
- Replace: `Tests/IntegrationTests/IntegrationPlaceholder.swift` → `Tests/IntegrationTests/VNCIntegrationTests.swift`

VMTestEnvironment manages a single persistent VM across test runs:
- **First ever run:** clones base image → `guivision-test` (slow, ~minutes)
- **Subsequent runs:** VM already exists, skips clone
- **Each test suite run:** starts the VM, provides VNC endpoint, stops when done
- **Cleanup:** `atexit` handler ensures the VM is stopped even on crash

- [ ] **Step 1: Implement VMTestEnvironment**

Create `Tests/TestSupport/VMTestEnvironment.swift`:

```swift
import Foundation
import GUIVisionVMDriver

/// Manages a single persistent tart macOS VM for integration testing.
///
/// Lifecycle:
/// 1. First call to `connectionSpec()` checks if VM exists
/// 2. If not → clones from base image (one-time, expensive ~5min)
/// 3. Starts the VM with VNC
/// 4. Returns a `ConnectionSpec` pointing at the VM
/// 5. Registers `atexit` to stop the VM when the test process exits
///
/// The VM is **not deleted** between runs — only stopped. This makes
/// subsequent test runs fast (just boot, not clone).
public final class VMTestEnvironment: @unchecked Sendable {
    public static let shared = VMTestEnvironment()

    /// The persistent VM name. Not deleted between runs.
    public let vmName = "guivision-test"

    /// Base image to clone from on first run.
    /// Uses the vanilla Sequoia image from Cirrus Labs.
    public let baseImage = "ghcr.io/cirruslabs/macos-sequoia-vanilla:latest"

    private let manager = VMManager()
    private let lock = NSLock()
    private var _endpoint: VNCEndpoint?
    private var _tartProcess: Process?
    private var _isStarted = false
    private var _atexitRegistered = false

    private init() {}

    // MARK: - Public API

    /// Get a ConnectionSpec for the test VM.
    /// Lazily creates and starts the VM if needed.
    /// Thread-safe — concurrent callers block until the VM is ready.
    public func connectionSpec() throws -> ConnectionSpec {
        try ensureRunning().connectionSpec
    }

    /// Get the VNC endpoint for the test VM.
    public func ensureRunning() throws -> VNCEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let endpoint = _endpoint, _isStarted {
            return endpoint
        }

        // Ensure VM exists (lazy creation)
        if !(try manager.vmExists(vmName)) {
            print("[VMTestEnvironment] VM '\(vmName)' not found. Cloning from \(baseImage)...")
            print("[VMTestEnvironment] This is a one-time operation and may take several minutes.")
            try manager.clone(from: baseImage, to: vmName)
            print("[VMTestEnvironment] Clone complete.")
        }

        // Stop if already running (stale from a previous crashed run)
        if let state = try? manager.vmState(vmName), state == "running" {
            print("[VMTestEnvironment] Stopping stale VM...")
            try? manager.stop(vm: vmName)
            Thread.sleep(forTimeInterval: 2)
        }

        // Start the VM
        print("[VMTestEnvironment] Starting VM '\(vmName)'...")
        let (process, endpoint) = try manager.start(vm: vmName, timeout: 120)

        self._tartProcess = process
        self._endpoint = endpoint
        self._isStarted = true

        print("[VMTestEnvironment] VM ready at vnc://\(endpoint.host):\(endpoint.port)")

        // Register atexit handler to stop the VM when tests finish
        registerAtExit()

        return endpoint
    }

    /// Stop the VM. Called by atexit or explicitly.
    public func stop() {
        lock.lock()
        let process = _tartProcess
        let started = _isStarted
        _tartProcess = nil
        _endpoint = nil
        _isStarted = false
        lock.unlock()

        guard started else { return }

        print("[VMTestEnvironment] Stopping VM '\(vmName)'...")
        try? manager.stop(vm: vmName)
        // Also terminate the background tart process if still running
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        print("[VMTestEnvironment] VM stopped.")
    }

    // MARK: - Private

    /// Reference to self held by the atexit closure, preventing premature dealloc.
    private static var _retainedForAtexit: VMTestEnvironment?

    private func registerAtExit() {
        guard !_atexitRegistered else { return }
        _atexitRegistered = true
        Self._retainedForAtexit = self
        atexit {
            VMTestEnvironment._retainedForAtexit?.stop()
        }
    }
}
```

- [ ] **Step 2: Implement VNC integration tests**

Delete `Tests/IntegrationTests/IntegrationPlaceholder.swift` and create `Tests/IntegrationTests/VNCIntegrationTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import GUIVisionVMDriver
import TestSupport

/// Integration tests that run against a real macOS VM via tart.
///
/// On first run, the VM is cloned from a base image (slow).
/// On subsequent runs, it boots the existing VM (fast).
///
/// Set GUIVISION_SKIP_INTEGRATION=1 to skip these tests
/// (e.g. in CI without tart, or when iterating on unit tests).
@Suite("VNC Integration",
       .enabled(if: ProcessInfo.processInfo.environment["GUIVISION_SKIP_INTEGRATION"] != "1"),
       .serialized)
struct VNCIntegrationTests {

    /// Shared connection spec — starts the VM on first access.
    static let spec: ConnectionSpec? = {
        // Allow override via env var for custom VNC targets
        if let vnc = ProcessInfo.processInfo.environment["GUIVISION_TEST_VNC"] {
            let password = ProcessInfo.processInfo.environment["GUIVISION_TEST_VNC_PASSWORD"]
            let platform = ProcessInfo.processInfo.environment["GUIVISION_TEST_PLATFORM"]
            return try? ConnectionSpec.from(vnc: vnc, platform: platform)
        }
        return try? VMTestEnvironment.shared.connectionSpec()
    }()

    // MARK: - Connection & Capture

    @Test func connectsToVNCServer() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let size = await capture.screenSize()
        #expect(size != nil)
        #expect(size!.width > 0)
        #expect(size!.height > 0)
    }

    @Test func capturesScreenshot() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let image = try await capture.captureImage()
        #expect(image.width > 0)
        #expect(image.height > 0)

        let png = try await capture.screenshot()
        #expect(png.count > 100)  // Non-trivial PNG
        #expect(png[0] == 0x89)   // PNG magic
        #expect(png[1] == 0x50)
    }

    @Test func capturesCroppedRegion() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let image = try await capture.captureImage(region: region)
        #expect(image.width == 100)
        #expect(image.height == 100)
    }

    // MARK: - Keyboard Input

    @Test func sendsKeyPress() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        // Send a key press — if no throw, the VNC server accepted it.
        try await capture.withConnection { conn in
            try VNCInput.pressKey("a", platform: spec.platform, connection: conn)
        }
    }

    @Test func sendsKeyWithModifiers() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.pressKey("a", modifiers: ["cmd"], platform: spec.platform, connection: conn)
        }
    }

    @Test func typesText() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.typeText("Hello!", connection: conn)
        }
    }

    // MARK: - Mouse Input

    @Test func sendsMouseClick() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: 500, y: 400, connection: conn)
            try VNCInput.click(x: 500, y: 400, connection: conn)
        }
    }

    @Test func sendsMouseDrag() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.drag(fromX: 100, fromY: 100, toX: 300, toY: 300,
                              steps: 5, connection: conn)
        }
    }

    @Test func sendsScroll() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.scroll(x: 500, y: 400, deltaX: 0, deltaY: -3, connection: conn)
        }
    }

    // MARK: - Cursor State

    @Test func readsCursorState() async throws {
        let spec = try #require(Self.spec, "VM not available")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        // Move mouse to trigger a cursor update
        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: 200, y: 200, connection: conn)
        }

        // Give the server time to send cursor update
        try await Task.sleep(for: .milliseconds(500))

        let cursor = await capture.cursorState
        // Cursor shape may or may not be reported depending on server config,
        // but the API should not crash.
        _ = cursor.position
        _ = cursor.size
    }
}
```

- [ ] **Step 3: Verify unit tests still pass (integration tests skipped by default)**

```bash
GUIVISION_SKIP_INTEGRATION=1 swift test
```

Expected: All unit tests pass. Integration tests are skipped.

- [ ] **Step 4: Run integration tests with tart VM**

```bash
swift test --filter IntegrationTests
```

Expected: On first run, VM is cloned (slow). VNC tests connect and pass. VM is stopped on exit.

On second run, VM already exists — only boots (faster).

- [ ] **Step 5: Commit**

```bash
git add Tests/TestSupport/VMTestEnvironment.swift Tests/IntegrationTests/
git rm Tests/IntegrationTests/IntegrationPlaceholder.swift 2>/dev/null || true
git commit -m "feat: VM test environment with lazy tart VM lifecycle and integration tests"
```

---

### Task 16: Full Test Suite Verification

- [ ] **Step 1: Run the complete unit test suite**

```bash
GUIVISION_SKIP_INTEGRATION=1 swift test
```

Expected: All unit tests pass.

- [ ] **Step 2: Run the integration test suite**

```bash
swift test --filter IntegrationTests
```

Expected: VM starts (or is already running), all integration tests pass, VM stops.

- [ ] **Step 3: Verify clean build**

```bash
swift package clean && swift build
```

Expected: Clean build succeeds.

- [ ] **Step 4: Verify CLI binary works**

```bash
swift run guivision --help
swift run guivision screenshot --help
swift run guivision input --help
swift run guivision input key --help
swift run guivision ssh --help
swift run guivision record --help
```

Expected: All help texts display correctly.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: verify full test suite and clean build"
```

---

## Summary

| Phase | Tasks | What it delivers |
|---|---|---|
| 1: Foundation | 1–3 | Package, connection types, framebuffer converter |
| 2: VNC Connection | 4–6 | Capture actor with delegate, cursor tracking, error types |
| 3: Input | 7–8 | Platform keymap, keyboard/mouse/scroll/drag input |
| 4: SSH | 9 | SSH client with ControlMaster, SCP transfers |
| 5: Streaming | 10 | Video recording from framebuffer to MP4 |
| 6: CLI | 11–13 | Full CLI with screenshot, input, ssh, record commands |
| 7: VM Test Infra | 14–16 | tart VM manager, lazy lifecycle, full integration tests |

**Total: 16 tasks, ~85 steps**

Each task is independently testable. All unit tests must pass before proceeding to the next task.

### Test Strategy

- **Unit tests** (`GUIVisionVMDriverTests`): Pure logic, no external dependencies. Run with `swift test` or `GUIVISION_SKIP_INTEGRATION=1 swift test`.
- **Integration tests** (`IntegrationTests`): Require a macOS VM via `tart`. Run with `swift test --filter IntegrationTests`. The VM is lazily created on first run (slow) and reused on subsequent runs (fast).
- **Override**: Set `GUIVISION_TEST_VNC=host:port` to point integration tests at a custom VNC server instead of the tart VM.
- **Skip integration**: Set `GUIVISION_SKIP_INTEGRATION=1` to skip VM-dependent tests (useful for fast iteration on unit tests).
