import Testing
import Foundation
import CoreGraphics
import GUIVisionVMDriver
import TestSupport

@Suite("VNC Integration",
       .enabled(if: ProcessInfo.processInfo.environment["GUIVISION_SKIP_INTEGRATION"] != "1"),
       .serialized)
struct VNCIntegrationTests {

    static let spec: ConnectionSpec? = {
        if let vnc = ProcessInfo.processInfo.environment["GUIVISION_TEST_VNC"] {
            let password = ProcessInfo.processInfo.environment["GUIVISION_TEST_VNC_PASSWORD"]
            let platform = ProcessInfo.processInfo.environment["GUIVISION_TEST_PLATFORM"]
            return try? ConnectionSpec.from(vnc: vnc, platform: platform)
        }
        return try? VMTestEnvironment.shared.connectionSpec()
    }()

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
        #expect(png.count > 100)
        #expect(png[0] == 0x89)
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

    @Test func sendsKeyPress() async throws {
        let spec = try #require(Self.spec, "VM not available")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }
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

    @Test func readsCursorState() async throws {
        let spec = try #require(Self.spec, "VM not available")
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect(timeout: .seconds(30))
        defer { Task { await capture.disconnect() } }
        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: 200, y: 200, connection: conn)
        }
        try await Task.sleep(for: .milliseconds(500))
        let cursor = await capture.cursorState
        _ = cursor.position
        _ = cursor.size
    }
}
