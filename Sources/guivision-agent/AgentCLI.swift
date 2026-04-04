import ArgumentParser
import GUIVisionAgentLib

@main
struct AgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision-agent",
        abstract: "In-VM accessibility agent for GUI automation",
        subcommands: [
            HealthCommand.self,
        ]
    )
}
