import ArgumentParser
import Foundation
import GUIVisionVMDriver

@main
struct GUIVisionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision",
        abstract: "VNC + agent driver for virtual machine automation",
        version: "0.2.0",
        subcommands: [
            ScreenshotCommand.self,
            ScreenSizeCommand.self,
            InputCommand.self,
            ExecCommand.self,
            UploadCommand.self,
            DownloadCommand.self,
            RecordCommand.self,
            FindTextCommand.self,
            ServerCommand.self,
            AgentCommand.self,
        ]
    )
}

/// Shared connection options used by all subcommands.
struct ConnectionOptions: ParsableArguments {
    @Option(name: .long, help: "Path to connection spec JSON file")
    var connect: String?

    @Option(name: .long, help: "VNC endpoint (host:port)")
    var vnc: String?

    @Option(name: .long, help: "Agent endpoint (host:port, default port 8648)")
    var agent: String?

    @Option(name: .long, help: "Target platform (macos, windows, linux)")
    var platform: String?

    func resolve() throws -> ConnectionSpec {
        if let connectPath = connect {
            return try ConnectionSpec.load(from: connectPath)
        } else if let vncEndpoint = vnc {
            return try ConnectionSpec.from(vnc: vncEndpoint, agent: agent, platform: platform)
        } else {
            throw ValidationError("Either --connect or --vnc is required")
        }
    }

    func resolveAgent() throws -> AgentTCPClient {
        // Allow agent-only usage without requiring --vnc
        if let agentEndpoint = agent {
            let agentSpec = try ConnectionSpec.parseAgentEndpoint(agentEndpoint)
            return AgentTCPClient(spec: agentSpec)
        }
        if let agentEnv = ProcessInfo.processInfo.environment["GUIVISION_AGENT"] {
            let agentSpec = try ConnectionSpec.parseAgentEndpoint(agentEnv)
            return AgentTCPClient(spec: agentSpec)
        }
        // Fall back to the full connection spec (which may include agent)
        if let spec = try? resolve(), let agentSpec = spec.agent {
            return AgentTCPClient(spec: agentSpec)
        }
        throw ValidationError("Agent endpoint required: use --agent host:port or set GUIVISION_AGENT")
    }
}
