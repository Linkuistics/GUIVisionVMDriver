import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("GUIVisionServer")
struct GUIVisionServerTests {

    // MARK: - Helpers

    private func makeServer(
        idleTimeout: Duration = .seconds(60),
        onShutdown: @escaping @Sendable () -> Void = {}
    ) -> GUIVisionServer {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        return GUIVisionServer(spec: spec, idleTimeout: idleTimeout, onShutdown: onShutdown)
    }

    private func request(_ method: String, _ path: String, body: String? = nil) -> HTTPRequest {
        HTTPRequest(method: method, path: path, body: body.map { Data($0.utf8) })
    }

    // MARK: - Health

    @Test func getHealthReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/health"))
        #expect(response.statusCode == 200)
    }

    @Test func getHealthReturnsStatusOK() async throws {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/health"))
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        #expect(json?["status"] == "ok")
    }

    @Test func postHealthReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/health"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Screen size

    @Test func getScreenSizeReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/screen-size"))
        #expect(response.statusCode == 200)
    }

    @Test func getScreenSizeReturnsWidthAndHeight() async throws {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/screen-size"))
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(json?["width"] != nil)
        #expect(json?["height"] != nil)
    }

    @Test func postScreenSizeReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/screen-size"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Screenshot

    @Test func postScreenshotReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/screenshot"))
        #expect(response.statusCode == 200)
    }

    @Test func getScreenshotReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/screenshot"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Input: /input/key

    @Test func postInputKeyReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/key", body: #"{"key":"a"}"#))
        #expect(response.statusCode == 200)
    }

    @Test func getInputKeyReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/input/key"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Input: /input/key-down and /input/key-up

    @Test func postInputKeyDownReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/key-down", body: #"{"key":"a"}"#))
        #expect(response.statusCode == 200)
    }

    @Test func postInputKeyUpReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/key-up", body: #"{"key":"a"}"#))
        #expect(response.statusCode == 200)
    }

    // MARK: - Input: /input/type

    @Test func postInputTypeReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/type", body: #"{"text":"hello"}"#))
        #expect(response.statusCode == 200)
    }

    @Test func getInputTypeReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/input/type"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Input: /input/click

    @Test func postInputClickReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/click", body: #"{"x":100,"y":200}"#))
        #expect(response.statusCode == 200)
    }

    @Test func getInputClickReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/input/click"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Input: /input/mouse-down and /input/mouse-up

    @Test func postInputMouseDownReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/mouse-down", body: #"{"x":100,"y":200}"#))
        #expect(response.statusCode == 200)
    }

    @Test func postInputMouseUpReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/mouse-up", body: #"{"x":100,"y":200}"#))
        #expect(response.statusCode == 200)
    }

    // MARK: - Input: /input/move, /input/scroll, /input/drag

    @Test func postInputMoveReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/move", body: #"{"x":100,"y":200}"#))
        #expect(response.statusCode == 200)
    }

    @Test func postInputScrollReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/scroll", body: #"{"x":100,"y":200,"dx":0,"dy":-3}"#))
        #expect(response.statusCode == 200)
    }

    @Test func postInputDragReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/input/drag", body: #"{"fromX":0,"fromY":0,"toX":100,"toY":100}"#))
        #expect(response.statusCode == 200)
    }

    // MARK: - SSH exec

    @Test func postSSHExecReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/ssh/exec", body: #"{"command":"ls"}"#))
        #expect(response.statusCode == 200)
    }

    @Test func getSSHExecReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/ssh/exec"))
        #expect(response.statusCode == 405)
    }

    // MARK: - SSH upload / download

    @Test func postSSHUploadReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/ssh/upload"))
        #expect(response.statusCode == 200)
    }

    @Test func getSSHUploadReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/ssh/upload"))
        #expect(response.statusCode == 405)
    }

    @Test func postSSHDownloadReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/ssh/download"))
        #expect(response.statusCode == 200)
    }

    @Test func getSSHDownloadReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/ssh/download"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Record

    @Test func postRecordStartReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/record/start"))
        #expect(response.statusCode == 200)
    }

    @Test func getRecordStartReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/record/start"))
        #expect(response.statusCode == 405)
    }

    @Test func postRecordStopReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/record/stop"))
        #expect(response.statusCode == 200)
    }

    @Test func getRecordStopReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/record/stop"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Stop

    @Test func postStopReturns200() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/stop"))
        #expect(response.statusCode == 200)
    }

    @Test func getStopReturns405() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/stop"))
        #expect(response.statusCode == 405)
    }

    // MARK: - Unknown paths

    @Test func unknownPathReturns404() async {
        let server = makeServer()
        let response = await server.handleRequest(request("GET", "/does-not-exist"))
        #expect(response.statusCode == 404)
    }

    @Test func unknownPOSTPathReturns404() async {
        let server = makeServer()
        let response = await server.handleRequest(request("POST", "/nope"))
        #expect(response.statusCode == 404)
    }

    // MARK: - Response content type

    @Test func allSuccessfulResponsesAreJSON() async {
        let server = makeServer()
        let routes: [(String, String)] = [
            ("GET", "/health"),
            ("GET", "/screen-size"),
            ("POST", "/screenshot"),
            ("POST", "/input/key"),
            ("POST", "/input/type"),
            ("POST", "/input/click"),
            ("POST", "/ssh/exec"),
            ("POST", "/record/start"),
            ("POST", "/record/stop"),
            ("POST", "/stop"),
        ]
        for (method, path) in routes {
            let response = await server.handleRequest(request(method, path))
            #expect(response.contentType == "application/json", "Expected JSON for \(method) \(path)")
        }
    }

    // MARK: - Idle timer

    @Test func idleTimerCallsShutdownAfterTimeout() async {
        let shutdownCalled = LockIsolated(false)
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let server = GUIVisionServer(
            spec: spec,
            idleTimeout: .milliseconds(100),
            onShutdown: { shutdownCalled.withLock { $0 = true } }
        )
        // Don't send any requests — let the timer fire naturally.
        // Wait up to 1 second for the shutdown to be called.
        let deadline = ContinuousClock().now + .seconds(1)
        while !shutdownCalled.withLock({ $0 }) {
            if ContinuousClock().now > deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = server  // keep alive
        #expect(shutdownCalled.withLock { $0 } == true)
    }

    @Test func idleTimerResetsOnRequest() async {
        let shutdownCalled = LockIsolated(false)
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let server = GUIVisionServer(
            spec: spec,
            idleTimeout: .milliseconds(200),
            onShutdown: { shutdownCalled.withLock { $0 = true } }
        )
        // Send requests every 50ms for 500ms — the timer should keep getting reset.
        for _ in 0..<10 {
            _ = await server.handleRequest(request("GET", "/health"))
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Timer should NOT have fired yet since we kept resetting it.
        #expect(shutdownCalled.withLock { $0 } == false)
        // Now wait for it to fire naturally.
        let deadline = ContinuousClock().now + .seconds(1)
        while !shutdownCalled.withLock({ $0 }) {
            if ContinuousClock().now > deadline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(shutdownCalled.withLock { $0 } == true)
    }
}

// MARK: - LockIsolated

/// A simple Sendable wrapper that protects a value with a lock.
/// Used in tests to safely observe side effects from @Sendable closures.
final class LockIsolated<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
