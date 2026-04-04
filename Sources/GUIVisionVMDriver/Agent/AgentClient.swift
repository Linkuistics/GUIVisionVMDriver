import Foundation
import GUIVisionAgentProtocol

/// Errors thrown by AgentClient.
public enum AgentClientError: Error, LocalizedError, Sendable {
    case agentError(String, details: String?)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .agentError(let message, let details):
            if let details {
                return "Agent error: \(message) — \(details)"
            } else {
                return "Agent error: \(message)"
            }
        case .decodingFailed(let detail):
            return "Failed to decode agent response: \(detail)"
        }
    }
}

/// Invokes the in-VM guivision-agent binary over SSH.
public final class AgentClient: Sendable {
    public static let defaultBinaryPath = "/usr/local/bin/guivision-agent"

    private let sshClient: SSHClient
    private let binaryPath: String

    public init(sshClient: SSHClient, binaryPath: String = AgentClient.defaultBinaryPath) {
        self.sshClient = sshClient
        self.binaryPath = binaryPath
    }

    // MARK: - Core

    /// Builds the full remote command string from a subcommand and arguments.
    public static func buildCommand(binaryPath: String, subcommand: String, args: [String]) -> String {
        let parts = [binaryPath, subcommand] + args
        return parts.joined(separator: " ")
    }

    /// Parses a decodable response type from JSON data.
    public static func parseResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AgentClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// Produces an AgentClientError from SSH result fields.
    public static func parseError(stdout: String, stderr: String, exitCode: Int32) -> AgentClientError {
        // Try stderr first, then stdout for the ErrorResponse JSON.
        let candidates = [stderr, stdout].filter { !$0.isEmpty }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                return .agentError(errorResponse.error, details: errorResponse.details)
            }
        }
        let combined = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: " / ")
        return .agentError("exit code \(exitCode)", details: combined.isEmpty ? nil : combined)
    }

    /// Executes a subcommand with the given arguments. Returns stdout as Data.
    /// Throws AgentClientError if the exit code is non-zero.
    @discardableResult
    public func exec(subcommand: String, args: [String] = []) throws -> Data {
        let command = Self.buildCommand(binaryPath: binaryPath, subcommand: subcommand, args: args)
        let result = try sshClient.exec(command)
        guard result.succeeded else {
            throw Self.parseError(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
        return Data(result.stdout.utf8)
    }

    // MARK: - Convenience Methods

    public func health() throws -> Data {
        try exec(subcommand: "health")
    }

    public func windows() throws -> Data {
        try exec(subcommand: "windows")
    }

    public func snapshot(
        mode: String? = nil,
        window: String? = nil,
        role: String? = nil,
        label: String? = nil,
        depth: Int? = nil
    ) throws -> Data {
        var args: [String] = []
        if let mode { args += ["--mode", mode] }
        if let window { args += ["--window", window] }
        if let role { args += ["--role", role] }
        if let label { args += ["--label", label] }
        if let depth { args += ["--depth", "\(depth)"] }
        return try exec(subcommand: "snapshot", args: args)
    }

    public func inspect(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil
    ) throws -> Data {
        try exec(subcommand: "inspect", args: elementArgs(role: role, label: label, window: window, id: id, index: index))
    }

    public func press(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil
    ) throws -> Data {
        try exec(subcommand: "press", args: elementArgs(role: role, label: label, window: window, id: id, index: index))
    }

    public func setValue(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil,
        value: String
    ) throws -> Data {
        var args = elementArgs(role: role, label: label, window: window, id: id, index: index)
        args += ["--value", value]
        return try exec(subcommand: "set-value", args: args)
    }

    public func focus(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil
    ) throws -> Data {
        try exec(subcommand: "focus", args: elementArgs(role: role, label: label, window: window, id: id, index: index))
    }

    public func showMenu(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil
    ) throws -> Data {
        try exec(subcommand: "show-menu", args: elementArgs(role: role, label: label, window: window, id: id, index: index))
    }

    public func windowFocus(window: String) throws -> Data {
        try exec(subcommand: "window-focus", args: ["--window", window])
    }

    public func windowResize(window: String, width: Int, height: Int) throws -> Data {
        try exec(subcommand: "window-resize", args: ["--window", window, "--width", "\(width)", "--height", "\(height)"])
    }

    public func windowMove(window: String, x: Int, y: Int) throws -> Data {
        try exec(subcommand: "window-move", args: ["--window", window, "--x", "\(x)", "--y", "\(y)"])
    }

    public func windowClose(window: String) throws -> Data {
        try exec(subcommand: "window-close", args: ["--window", window])
    }

    public func windowMinimize(window: String) throws -> Data {
        try exec(subcommand: "window-minimize", args: ["--window", window])
    }

    public func screenshotWindow(window: String, output: String) throws -> Data {
        try exec(subcommand: "screenshot-window", args: ["--window", window, "--output", output])
    }

    public func screenshotElement(
        role: String? = nil,
        label: String? = nil,
        window: String? = nil,
        id: String? = nil,
        index: Int? = nil,
        padding: Int? = nil,
        output: String
    ) throws -> Data {
        var args = elementArgs(role: role, label: label, window: window, id: id, index: index)
        if let padding { args += ["--padding", "\(padding)"] }
        args += ["--output", output]
        return try exec(subcommand: "screenshot-element", args: args)
    }

    public func screenshotRegion(
        window: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        output: String
    ) throws -> Data {
        try exec(subcommand: "screenshot-region", args: [
            "--window", window,
            "--x", "\(x)", "--y", "\(y)",
            "--width", "\(width)", "--height", "\(height)",
            "--output", output,
        ])
    }

    public func wait(window: String? = nil, timeout: Int? = nil) throws -> Data {
        var args: [String] = []
        if let window { args += ["--window", window] }
        if let timeout { args += ["--timeout", "\(timeout)"] }
        return try exec(subcommand: "wait", args: args)
    }

    // MARK: - Private Helpers

    private func elementArgs(
        role: String?,
        label: String?,
        window: String?,
        id: String?,
        index: Int?
    ) -> [String] {
        var args: [String] = []
        if let role { args += ["--role", role] }
        if let label { args += ["--label", label] }
        if let window { args += ["--window", window] }
        if let id { args += ["--id", id] }
        if let index { args += ["--index", "\(index)"] }
        return args
    }
}
