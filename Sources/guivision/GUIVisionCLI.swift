import ArgumentParser

@main
struct GUIVisionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision",
        abstract: "VNC + SSH driver for virtual machine automation",
        version: "0.1.0"
    )

    mutating func run() async throws {
        print("guivision 0.1.0 — use --help for available commands")
    }
}
