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
public final class VMManager: Sendable {
    public enum Command {
        case run, clone, stop, delete, list
    }

    private let tartPath: String

    public init(tartPath: String = "/opt/homebrew/bin/tart") {
        self.tartPath = tartPath
    }

    // MARK: - Argument Building (public for testing)

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

    public static func parseVNCURL(from output: String) -> VNCEndpoint? {
        guard let range = output.range(of: "vnc://[^\\s]+", options: .regularExpression) else {
            return nil
        }
        let urlString = String(output[range]).replacingOccurrences(of: "...", with: "")
        guard let url = URL(string: urlString) else { return nil }
        let password = url.password ?? ""
        let host = url.host ?? "localhost"
        let port = url.port ?? 5900
        return VNCEndpoint(host: host, port: port, password: password)
    }

    public static func vmExistsInList(vmName: String, listOutput: String) -> Bool {
        vmStateInList(vmName: vmName, listOutput: listOutput) != nil
    }

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

    public func vmExists(_ name: String) throws -> Bool {
        let output = try runTart(Self.tartArguments(for: .list, vm: ""))
        return Self.vmExistsInList(vmName: name, listOutput: output)
    }

    public func vmState(_ name: String) throws -> String? {
        let output = try runTart(Self.tartArguments(for: .list, vm: ""))
        return Self.vmStateInList(vmName: name, listOutput: output)
    }

    public func clone(from base: String, to name: String) throws {
        try runTart(Self.tartArguments(for: .clone, vm: base, destination: name))
    }

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

    /// Get the IP address of a running VM via `tart ip`.
    /// Polls until the IP is available or timeout is reached.
    public func vmIP(_ name: String, timeout: TimeInterval = 60) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ip = try? runTart(["ip", name]).trimmingCharacters(in: .whitespacesAndNewlines),
               !ip.isEmpty {
                return ip
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw VMManagerError.timeout("Could not get IP for VM '\(name)' within \(Int(timeout))s")
    }

    /// Wait for SSH to become reachable on the given host.
    public func waitForSSH(host: String, port: Int = 22, user: String = "admin", timeout: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=5",
                "-p", "\(port)",
                "\(user)@\(host)",
                "echo ok",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return true
                }
            } catch {}
            Thread.sleep(forTimeInterval: 3)
        }
        return false
    }

    public func stop(vm: String) throws {
        try runTart(Self.tartArguments(for: .stop, vm: vm))
    }

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
