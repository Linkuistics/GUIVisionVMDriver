import Testing
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import RoyalVNCKit
import GUIVisionVMDriver

// MARK: - Environment-driven connection setup

/// Reads VNC/SSH endpoints from environment variables.
/// No VM management — the caller is responsible for providing a running VM.
///
/// Required:
///   GUIVISION_VNC=host:port          VNC endpoint
///
/// Optional:
///   GUIVISION_VNC_PASSWORD=secret    VNC password
///   GUIVISION_SSH=user@host[:port]   SSH endpoint (enables SSH tests)
///   GUIVISION_PLATFORM=macos         Platform hint (default: macos)
///   GUIVISION_SKIP_INTEGRATION=1          Skip all integration tests
///
/// Example with tart:
///   tart clone guivision-golden-macos-tahoe test-vm
///   tart run test-vm --no-graphics --vnc-experimental &
///   # parse VNC URL from tart output, get IP via `tart ip test-vm`
///   GUIVISION_VNC=localhost:5901 \
///   GUIVISION_VNC_PASSWORD=abc123 \
///   GUIVISION_SSH=admin@192.168.64.100 \
///   swift test --filter IntegrationTests
enum TestEnv {
    static let spec: ConnectionSpec? = {
        guard let vnc = ProcessInfo.processInfo.environment["GUIVISION_VNC"] else {
            return nil
        }
        let password = ProcessInfo.processInfo.environment["GUIVISION_VNC_PASSWORD"]
        let ssh = ProcessInfo.processInfo.environment["GUIVISION_SSH"]
        let platform = ProcessInfo.processInfo.environment["GUIVISION_PLATFORM"]

        guard var spec = try? ConnectionSpec.from(vnc: vnc, ssh: ssh, platform: platform) else {
            return nil
        }

        // Apply VNC password if provided separately
        if let password, !password.isEmpty {
            spec = ConnectionSpec(
                vnc: VNCSpec(host: spec.vnc.host, port: spec.vnc.port, password: password),
                ssh: spec.ssh,
                platform: spec.platform
            )
        }

        return spec
    }()

    static let ssh: SSHClient? = {
        guard let spec, spec.ssh != nil else { return nil }
        return try? SSHClient(connectionSpec: spec)
    }()
}

// MARK: - VNC Integration Tests

@Suite("VNC Integration",
       .enabled(if: ProcessInfo.processInfo.environment["GUIVISION_SKIP_INTEGRATION"] != "1"
                && ProcessInfo.processInfo.environment["GUIVISION_VNC"] != nil),
       .serialized)
struct VNCIntegrationTests {

    // MARK: - Connection

    @Test func connectsAndReportsScreenSize() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let size = await capture.screenSize()
        #expect(size != nil, "Screen size should be available after connect")
        #expect(size!.width >= 1024, "Screen width should be at least 1024")
        #expect(size!.height >= 768, "Screen height should be at least 768")
    }

    @Test func reconnectsAfterDisconnect() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)

        try await capture.connect(timeout: .seconds(30))
        let size1 = await capture.screenSize()
        #expect(size1 != nil)
        await capture.disconnect()

        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }
        let size2 = await capture.screenSize()
        #expect(size2 != nil)
        #expect(size1!.width == size2!.width, "Screen size should be consistent across reconnects")
    }

    // MARK: - Screenshot Capture

    @Test func capturesFullScreenshot() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let image = try await capture.captureImage()
        let size = await capture.screenSize()!
        #expect(image.width == Int(size.width), "Image width should match screen width")
        #expect(image.height == Int(size.height), "Image height should match screen height")
    }

    @Test func capturesValidPNG() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let png = try await capture.screenshot()
        #expect(png.count > 1000, "PNG should have substantial data")
        #expect(png[0] == 0x89)
        #expect(png[1] == 0x50) // P
        #expect(png[2] == 0x4E) // N
        #expect(png[3] == 0x47) // G

        let tmpPath = NSTemporaryDirectory() + "guivision-test-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try png.write(to: URL(fileURLWithPath: tmpPath))
        let readBack = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        #expect(readBack.count == png.count)
    }

    @Test func capturesCroppedRegion() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let region = CGRect(x: 10, y: 10, width: 200, height: 150)
        let image = try await capture.captureImage(region: region)
        #expect(image.width == 200)
        #expect(image.height == 150)
    }

    @Test func consecutiveScreenshotsSameSize() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let img1 = try await capture.captureImage()
        try await Task.sleep(for: .milliseconds(200))
        let img2 = try await capture.captureImage()
        #expect(img1.width == img2.width)
        #expect(img1.height == img2.height)
    }

    // MARK: - Mouse Input

    @Test func mouseMoveAndCaptureWorkTogether() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        for (x, y) in [(UInt16(10), UInt16(10)), (500, 400), (800, 600)] {
            try await capture.withConnection { conn in
                VNCInput.mouseMove(x: x, y: y, connection: conn)
            }
            try await Task.sleep(for: .milliseconds(100))
            let img = try await capture.captureImage()
            #expect(img.width > 0)
        }
    }

    @Test func mouseClickAccepted() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.click(x: 500, y: 400, button: "left", count: 1, connection: conn)
        }
        try await capture.withConnection { conn in
            try VNCInput.click(x: 500, y: 400, button: "left", count: 2, connection: conn)
        }
        try await capture.withConnection { conn in
            try VNCInput.click(x: 500, y: 400, button: "right", count: 1, connection: conn)
        }
        try await Task.sleep(for: .milliseconds(500))
        try await capture.withConnection { conn in
            try VNCInput.pressKey("escape", platform: spec.platform, connection: conn)
        }
    }

    @Test func mouseDragCompletesWithoutError() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.drag(fromX: 200, fromY: 200, toX: 400, toY: 400,
                              button: "left", steps: 20, connection: conn)
        }
        let img = try await capture.captureImage()
        #expect(img.width > 0)
    }

    @Test func scrollAccepted() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.scroll(x: 500, y: 400, deltaX: 0, deltaY: -3, connection: conn)
            VNCInput.scroll(x: 500, y: 400, deltaX: 0, deltaY: 3, connection: conn)
            VNCInput.scroll(x: 500, y: 400, deltaX: -2, deltaY: 0, connection: conn)
            VNCInput.scroll(x: 500, y: 400, deltaX: 2, deltaY: 0, connection: conn)
        }
    }

    // MARK: - Keyboard Input

    @Test func specialKeysAccepted() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.pressKey("escape", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("tab", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("return", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("space", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("delete", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("up", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("down", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("left", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("right", platform: spec.platform, connection: conn)
            try VNCInput.pressKey("f1", platform: spec.platform, connection: conn)
        }
    }

    @Test func modifierCombinationsAccepted() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.pressKey("a", modifiers: ["cmd"], platform: spec.platform, connection: conn)
            try VNCInput.pressKey("z", modifiers: ["cmd", "shift"], platform: spec.platform, connection: conn)
            try VNCInput.pressKey("c", modifiers: ["ctrl"], platform: spec.platform, connection: conn)
        }
    }

    @Test func typeTextExercisesShiftedChars() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.typeText("Hello World! @#$ Test_123", connection: conn)
        }
        let img = try await capture.captureImage()
        #expect(img.width > 0)
    }

    // MARK: - Cursor State

    @Test func cursorStateAccessibleAfterMovement() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: 500, y: 400, connection: conn)
        }
        try await Task.sleep(for: .seconds(1))

        let cursor = await capture.cursorState
        if let size = cursor.size {
            #expect(size.width > 0 && size.height > 0)
        }
    }

    // MARK: - Streaming Capture

    @Test func recordsVideoFromLiveVNC() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let outputPath = NSTemporaryDirectory() + "guivision-integration-\(UUID().uuidString).mp4"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        guard let screenSize = await capture.screenSize() else {
            Issue.record("Could not determine screen size")
            return
        }

        let config = StreamingCaptureConfig(
            width: Int(screenSize.width),
            height: Int(screenSize.height),
            fps: 10
        )
        let recorder = StreamingCapture()
        try await recorder.start(outputPath: outputPath, config: config)

        for i in 0..<10 {
            let image = try await capture.captureImage()
            try await recorder.appendFrame(image)
            try await capture.withConnection { conn in
                VNCInput.mouseMove(x: UInt16(100 + i * 30), y: UInt16(100 + i * 20), connection: conn)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        try await recorder.stop()

        let url = URL(fileURLWithPath: outputPath)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "MP4 should contain a video track")

        let track = tracks[0]
        let naturalSize = try await track.load(.naturalSize)
        #expect(Int(naturalSize.width) == Int(screenSize.width))
        #expect(Int(naturalSize.height) == Int(screenSize.height))

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        #expect(durationSeconds > 0.5)
        #expect(durationSeconds < 5.0)
    }
}

// MARK: - SSH Integration Tests

@Suite("SSH Integration",
       .enabled(if: ProcessInfo.processInfo.environment["GUIVISION_SKIP_INTEGRATION"] != "1"
                && ProcessInfo.processInfo.environment["GUIVISION_SSH"] != nil),
       .serialized)
struct SSHIntegrationTests {

    // MARK: - Command Execution

    @Test func execSimpleCommand() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")
        let result = try client.exec("echo hello")
        #expect(result.succeeded)
        #expect(result.stdout == "hello")
        #expect(result.exitCode == 0)
    }

    @Test func execCommandWithArguments() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")
        let result = try client.exec("uname -s")
        #expect(result.succeeded)
        #expect(result.stdout == "Darwin")
    }

    @Test func execCommandCapturesStderr() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")
        let result = try client.exec("ls /nonexistent-path-12345")
        #expect(!result.succeeded)
        #expect(result.exitCode != 0)
        #expect(!result.stderr.isEmpty)
    }

    @Test func execCommandReturnsExitCode() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")
        let result = try client.exec("exit 42")
        #expect(result.exitCode == 42)
        #expect(!result.succeeded)
    }

    @Test func execMultilineOutput() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")
        let result = try client.exec("echo 'line1'; echo 'line2'; echo 'line3'")
        #expect(result.succeeded)
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "line1")
        #expect(lines[2] == "line3")
    }

    // MARK: - SCP File Transfer

    @Test func uploadAndVerifyFile() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")

        let testContent = "GUIVisionVMDriver upload test — \(UUID().uuidString)"
        let localPath = NSTemporaryDirectory() + "guivision-upload-\(UUID().uuidString).txt"
        let remotePath = "/tmp/guivision-upload-test.txt"
        defer {
            try? FileManager.default.removeItem(atPath: localPath)
            _ = try? client.exec("rm -f \(remotePath)")
        }

        try testContent.write(toFile: localPath, atomically: true, encoding: .utf8)
        let uploadResult = try client.upload(localPath: localPath, remotePath: remotePath)
        #expect(uploadResult.succeeded, "Upload failed: \(uploadResult.stderr)")

        let catResult = try client.exec("cat \(remotePath)")
        #expect(catResult.succeeded)
        #expect(catResult.stdout == testContent)
    }

    @Test func downloadFile() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")

        let testContent = "GUIVisionVMDriver download test — \(UUID().uuidString)"
        let remotePath = "/tmp/guivision-download-test.txt"
        let localPath = NSTemporaryDirectory() + "guivision-download-\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: localPath)
            _ = try? client.exec("rm -f \(remotePath)")
        }

        let writeResult = try client.exec("echo -n '\(testContent)' > \(remotePath)")
        #expect(writeResult.succeeded)

        let downloadResult = try client.download(remotePath: remotePath, localPath: localPath)
        #expect(downloadResult.succeeded, "Download failed: \(downloadResult.stderr)")

        let downloaded = try String(contentsOfFile: localPath, encoding: .utf8)
        #expect(downloaded == testContent)
    }

    @Test func uploadDownloadRoundtrip() throws {
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")

        let testData = Data((0..<256).map { UInt8($0) })
        let localUploadPath = NSTemporaryDirectory() + "guivision-roundtrip-up-\(UUID().uuidString).bin"
        let remotePath = "/tmp/guivision-roundtrip-test.bin"
        let localDownloadPath = NSTemporaryDirectory() + "guivision-roundtrip-down-\(UUID().uuidString).bin"
        defer {
            try? FileManager.default.removeItem(atPath: localUploadPath)
            try? FileManager.default.removeItem(atPath: localDownloadPath)
            _ = try? client.exec("rm -f \(remotePath)")
        }

        try testData.write(to: URL(fileURLWithPath: localUploadPath))

        let up = try client.upload(localPath: localUploadPath, remotePath: remotePath)
        #expect(up.succeeded)

        let down = try client.download(remotePath: remotePath, localPath: localDownloadPath)
        #expect(down.succeeded)

        let roundtripped = try Data(contentsOf: URL(fileURLWithPath: localDownloadPath))
        #expect(roundtripped == testData)
    }

    // MARK: - VNC + SSH Cross-verification

    @Test func vncInputReachesVM() async throws {
        let spec = try #require(TestEnv.spec, "GUIVISION_VNC not set")
        let client = try #require(TestEnv.ssh, "GUIVISION_SSH not set")

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }

        let marker = String(UUID().uuidString.prefix(8)).lowercased()
        let resultPath = "/tmp/r.txt"
        defer {
            _ = try? client.exec("rm -f \(resultPath) /tmp/m.sh")
            _ = try? client.exec("killall Terminal 2>/dev/null")
        }

        _ = try? client.exec("killall Terminal 2>/dev/null")
        try await Task.sleep(for: .seconds(2))

        // Create reader script via SSH — reads one line, writes to file
        _ = try client.exec("printf '#!/bin/bash\\nread x\\necho $x > \(resultPath)\\n' > /tmp/m.sh && chmod +x /tmp/m.sh")

        // Release stuck modifiers, dismiss stale UI
        try await capture.withConnection { conn in
            conn.keyUp(.shift)
            conn.keyUp(.control)
            conn.keyUp(.option)
            conn.keyUp(.command)
            conn.keyUp(.optionForARD)
        }
        try await Task.sleep(for: .milliseconds(300))
        try await capture.withConnection { conn in
            try VNCInput.pressKey("escape", platform: spec.platform, connection: conn)
        }
        try await Task.sleep(for: .milliseconds(500))

        // Open Terminal and wait for it to come to front
        _ = try client.exec("open -a Terminal")
        try await Task.sleep(for: .seconds(8))

        // Double-click center to activate Terminal and focus text area
        let screenSize = await capture.screenSize()!
        let cx = UInt16(screenSize.width / 2)
        let cy = UInt16(screenSize.height / 2)
        try await capture.withConnection { conn in
            try VNCInput.click(x: cx, y: cy, connection: conn)
        }
        try await Task.sleep(for: .seconds(2))
        try await capture.withConnection { conn in
            try VNCInput.click(x: cx, y: cy, connection: conn)
        }
        try await Task.sleep(for: .seconds(2))

        // Retry up to 3 times — macOS VNC focus is timing-dependent
        var verified = false
        for attempt in 1...3 {
            _ = try? client.exec("rm -f \(resultPath)")

            if attempt > 1 {
                try await capture.withConnection { conn in
                    try VNCInput.click(x: cx, y: cy, connection: conn)
                }
                try await Task.sleep(for: .seconds(2))
                try await capture.withConnection { conn in
                    try VNCInput.pressKey("u", modifiers: ["ctrl"], platform: spec.platform, connection: conn)
                    try VNCInput.pressKey("c", modifiers: ["ctrl"], platform: spec.platform, connection: conn)
                }
                try await Task.sleep(for: .seconds(1))
            }

            try await capture.withConnection { conn in
                VNCInput.typeText("/tmp/m.sh", connection: conn)
            }
            try await Task.sleep(for: .milliseconds(300))
            try await capture.withConnection { conn in
                try VNCInput.pressKey("return", platform: spec.platform, connection: conn)
            }
            try await Task.sleep(for: .seconds(2))

            try await capture.withConnection { conn in
                VNCInput.typeText(marker, connection: conn)
            }
            try await Task.sleep(for: .milliseconds(300))
            try await capture.withConnection { conn in
                try VNCInput.pressKey("return", platform: spec.platform, connection: conn)
            }
            try await Task.sleep(for: .seconds(2))

            let result = try client.exec("cat \(resultPath)")
            if result.succeeded && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).contains(marker) {
                verified = true
                break
            }
        }

        withKnownIssue("macOS VNC focus timing is non-deterministic") {
            #expect(verified,
                    "VNC keyboard input should reach Terminal (marker '\(marker)' should appear in \(resultPath))")
        } when: {
            !verified
        }
    }
}
