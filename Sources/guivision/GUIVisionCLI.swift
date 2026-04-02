import ArgumentParser
import GUIVisionVMDriver

@main
struct GUIVisionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision",
        abstract: "VNC + SSH driver for virtual machine automation",
        version: "0.1.0",
        subcommands: [
            ScreenshotCommand.self,
            InputCommand.self,
        ]
    )
}

/// Shared connection options used by all subcommands.
struct ConnectionOptions: ParsableArguments {
    @Option(name: .long, help: "Path to connection spec JSON file")
    var connect: String?

    @Option(name: .long, help: "VNC endpoint (host:port)")
    var vnc: String?

    @Option(name: .long, help: "SSH endpoint (user@host[:port])")
    var ssh: String?

    @Option(name: .long, help: "Target platform (macos, windows, linux)")
    var platform: String?

    func resolve() throws -> ConnectionSpec {
        if let connectPath = connect {
            return try ConnectionSpec.load(from: connectPath)
        } else if let vncEndpoint = vnc {
            return try ConnectionSpec.from(vnc: vncEndpoint, ssh: ssh, platform: platform)
        } else {
            throw ValidationError("Either --connect or --vnc is required")
        }
    }
}
