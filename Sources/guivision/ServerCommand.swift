import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct ServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_server",
        abstract: "Internal server process (not for direct use)",
        shouldDisplay: false
    )

    @Option(name: .long, help: "JSON-encoded ConnectionSpec")
    var connectJson: String

    @Option(name: .long, help: "Idle timeout in seconds")
    var idleTimeout: Int = 10

    mutating func run() async throws {
        let data = Data(connectJson.utf8)
        let spec = try JSONDecoder().decode(ConnectionSpec.self, from: data)

        let server = GUIVisionServer(
            spec: spec,
            idleTimeout: .seconds(idleTimeout),
            onShutdown: { Foundation.exit(0) }
        )

        try await server.connect()

        let socketPath = ServerClient.socketPath(for: spec)
        let pidPath = ServerClient.pidPath(for: spec)
        try await server.start(socketPath: socketPath, pidPath: pidPath)

        print("ready")
        fflush(stdout)

        // Await indefinitely; the process is terminated by the idle timer (exit(0))
        // or by the /stop endpoint.
        try await Task.sleep(for: .seconds(100 * 365 * 24 * 3600))
    }
}
