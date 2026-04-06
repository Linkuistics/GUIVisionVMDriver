import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("Server")
struct ServerTests {

    // MARK: - Helpers

    private func makeServer(
        idleTimeout: Duration = .seconds(60),
        onShutdown: @escaping @Sendable () -> Void = {}
    ) -> GUIVisionServer {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        return GUIVisionServer(spec: spec, idleTimeout: idleTimeout, onShutdown: onShutdown)
    }

    // MARK: - Health handler

    @Test func healthReturnsOK() async {
        let server = makeServer()
        let response = await server.handleHealth()
        #expect(response.status == .ok)
    }

    // MARK: - Screen size without VNC

    @Test func screenSizeReturns503WithoutVNC() async {
        let server = makeServer()
        let response = await server.handleScreenSize()
        #expect(response.status == .serviceUnavailable)
    }

    // MARK: - Stop handler

    @Test func stopReturnsOK() async {
        let server = makeServer()
        let response = await server.handleStop()
        #expect(response.status == .ok)
    }

    // MARK: - Record stop returns OK

    @Test func recordStopReturnsOK() async {
        let server = makeServer()
        let response = await server.handleRecordStop()
        #expect(response.status == .ok)
    }

    // MARK: - Idle timer

    @Test func idleTimerFires() async {
        let shutdownCalled = LockIsolated(false)
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let server = GUIVisionServer(
            spec: spec,
            idleTimeout: .milliseconds(100),
            onShutdown: { shutdownCalled.withLock { $0 = true } }
        )
        let deadline = ContinuousClock().now + .seconds(1)
        while !shutdownCalled.withLock({ $0 }) {
            if ContinuousClock().now > deadline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = server
        #expect(shutdownCalled.withLock { $0 } == true)
    }

    @Test func idleTimerResets() async throws {
        let shutdownCalled = LockIsolated(false)
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let server = GUIVisionServer(
            spec: spec,
            idleTimeout: .milliseconds(200),
            onShutdown: { shutdownCalled.withLock { $0 = true } }
        )
        for _ in 0..<10 {
            _ = await server.handleHealth()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shutdownCalled.withLock { $0 } == false)
        let deadline = ContinuousClock().now + .seconds(1)
        while !shutdownCalled.withLock({ $0 }) {
            if ContinuousClock().now > deadline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(shutdownCalled.withLock { $0 } == true)
    }
}

// MARK: - LockIsolated

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
