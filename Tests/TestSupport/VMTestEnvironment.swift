import Foundation
import GUIVisionVMDriver

/// Manages a single persistent tart macOS VM for integration testing.
///
/// Uses the golden image which has SSH pre-configured with the host's
/// SSH key authorized. Provides both VNC and SSH access to the VM.
public final class VMTestEnvironment: @unchecked Sendable {
    public static let shared = VMTestEnvironment()

    public let vmName = "guivision-test"

    /// Golden image with SSH, Homebrew, and tools pre-configured.
    public let baseImage = "testanyware-golden-tahoe"

    /// SSH user on the golden image.
    public let sshUser = "admin"

    private let manager = VMManager()
    private let lock = NSLock()
    private var _endpoint: VNCEndpoint?
    private var _vmIP: String?
    private var _tartProcess: Process?
    private var _isStarted = false
    private var _atexitRegistered = false

    private init() {}

    /// Get a ConnectionSpec with both VNC and SSH for the test VM.
    public func connectionSpec() throws -> ConnectionSpec {
        let endpoint = try ensureRunning()
        guard let vmIP = _vmIP else {
            return endpoint.connectionSpec
        }
        let sshSpec = SSHSpec(host: vmIP, port: 22, user: sshUser)
        return ConnectionSpec(
            vnc: endpoint.vncSpec,
            ssh: sshSpec,
            platform: .macos
        )
    }

    /// Get the SSH client for the test VM, or nil if SSH is not available.
    public func sshClient() throws -> SSHClient? {
        let spec = try connectionSpec()
        guard spec.ssh != nil else { return nil }
        return try SSHClient(connectionSpec: spec)
    }

    public func ensureRunning() throws -> VNCEndpoint {
        lock.lock()
        defer { lock.unlock() }

        if let endpoint = _endpoint, _isStarted {
            return endpoint
        }

        // Check if golden image exists
        if !(try manager.vmExists(baseImage)) {
            throw VMTestEnvironmentError.goldenImageMissing(baseImage)
        }

        // Clone from golden if test VM doesn't exist
        if !(try manager.vmExists(vmName)) {
            print("[VMTestEnvironment] VM '\(vmName)' not found. Cloning from \(baseImage)...")
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

        print("[VMTestEnvironment] VNC ready at vnc://\(endpoint.host):\(endpoint.port)")

        // Get VM IP for SSH
        print("[VMTestEnvironment] Waiting for VM IP...")
        if let ip = try? manager.vmIP(vmName, timeout: 60) {
            self._vmIP = ip
            print("[VMTestEnvironment] VM IP: \(ip)")

            // Wait for SSH to become reachable
            print("[VMTestEnvironment] Waiting for SSH...")
            if manager.waitForSSH(host: ip, user: sshUser, timeout: 120) {
                print("[VMTestEnvironment] SSH ready at \(sshUser)@\(ip)")
            } else {
                print("[VMTestEnvironment] WARNING: SSH not reachable — SSH tests will be skipped")
                self._vmIP = nil
            }
        } else {
            print("[VMTestEnvironment] WARNING: Could not get VM IP — SSH tests will be skipped")
        }

        registerAtExit()

        return endpoint
    }

    public func stop() {
        lock.lock()
        let process = _tartProcess
        let started = _isStarted
        _tartProcess = nil
        _endpoint = nil
        _vmIP = nil
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

public enum VMTestEnvironmentError: Error, LocalizedError {
    case goldenImageMissing(String)

    public var errorDescription: String? {
        switch self {
        case .goldenImageMissing(let name):
            "Golden image '\(name)' not found. Create it first with TestAnyware: testanyware vm create"
        }
    }
}
