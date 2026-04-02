import Foundation

/// Result of an SSH command execution.
public struct SSHResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

/// SSH client using OpenSSH ControlMaster for persistent connections.
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

    @discardableResult
    public func exec(_ command: String, timeout: TimeInterval = 30) throws -> SSHResult {
        let args = sshArguments(for: command)
        return try runProcess("/usr/bin/ssh", arguments: args, timeout: timeout)
    }

    // MARK: - File Transfer

    public func upload(localPath: String, remotePath: String, timeout: TimeInterval = 60) throws -> SSHResult {
        let args = scpUploadArguments(localPath: localPath, remotePath: remotePath)
        return try runProcess("/usr/bin/scp", arguments: args, timeout: timeout)
    }

    public func download(remotePath: String, localPath: String, timeout: TimeInterval = 60) throws -> SSHResult {
        let args = scpDownloadArguments(remotePath: remotePath, localPath: localPath)
        return try runProcess("/usr/bin/scp", arguments: args, timeout: timeout)
    }

    // MARK: - Connection Management

    public func connect(timeout: TimeInterval = 10) throws {
        let args = baseSSHArguments() + [
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=300",
            "-N", "-f",
            "\(user)@\(host)",
        ]
        let result = try runProcess("/usr/bin/ssh", arguments: args, timeout: timeout)
        if !result.succeeded {
            throw SSHClientError.connectionFailed(result.stderr)
        }
    }

    public func disconnect() {
        let args = baseSSHArguments() + [
            "-O", "exit",
            "\(user)@\(host)",
        ]
        _ = try? runProcess("/usr/bin/ssh", arguments: args, timeout: 5)
    }

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
