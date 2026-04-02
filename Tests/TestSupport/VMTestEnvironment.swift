import Foundation
import GUIVisionVMDriver

/// Manages a single persistent tart macOS VM for integration testing.
public final class VMTestEnvironment: @unchecked Sendable {
    public static let shared = VMTestEnvironment()

    public let vmName = "guivision-test"
    public let baseImage = "ghcr.io/cirruslabs/macos-sequoia-vanilla:latest"

    private let manager = VMManager()
    private let lock = NSLock()
    private var _endpoint: VNCEndpoint?
    private var _tartProcess: Process?
    private var _isStarted = false
    private var _atexitRegistered = false

    private init() {}

    public func connectionSpec() throws -> ConnectionSpec {
        try ensureRunning().connectionSpec
    }

    public func ensureRunning() throws -> VNCEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let endpoint = _endpoint, _isStarted {
            return endpoint
        }

        if !(try manager.vmExists(vmName)) {
            print("[VMTestEnvironment] VM '\(vmName)' not found. Cloning from \(baseImage)...")
            print("[VMTestEnvironment] This is a one-time operation and may take several minutes.")
            try manager.clone(from: baseImage, to: vmName)
            print("[VMTestEnvironment] Clone complete.")
        }

        if let state = try? manager.vmState(vmName), state == "running" {
            print("[VMTestEnvironment] Stopping stale VM...")
            try? manager.stop(vm: vmName)
            Thread.sleep(forTimeInterval: 2)
        }

        print("[VMTestEnvironment] Starting VM '\(vmName)'...")
        let (process, endpoint) = try manager.start(vm: vmName, timeout: 120)

        self._tartProcess = process
        self._endpoint = endpoint
        self._isStarted = true

        print("[VMTestEnvironment] VM ready at vnc://\(endpoint.host):\(endpoint.port)")

        registerAtExit()

        return endpoint
    }

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
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        print("[VMTestEnvironment] VM stopped.")
    }

    private nonisolated(unsafe) static var _retainedForAtexit: VMTestEnvironment?

    private func registerAtExit() {
        guard !_atexitRegistered else { return }
        _atexitRegistered = true
        Self._retainedForAtexit = self
        atexit {
            VMTestEnvironment._retainedForAtexit?.stop()
        }
    }
}
