import ArgumentParser

@main
struct AgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision-agent",
        abstract: "In-VM accessibility agent for GUI automation"
    )

    func run() async throws {
        print("guivision-agent: use a subcommand")
    }
}
