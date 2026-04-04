import ArgumentParser
import ApplicationServices
import Darwin

struct HealthResponse: Encodable {
    let accessible: Bool
    let platform: String
}

struct HealthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check accessibility permissions and agent health"
    )

    func run() throws {
        let trusted = AXIsProcessTrusted()
        let response = HealthResponse(accessible: trusted, platform: "macos")
        JSONOutput.write(response)
        if !trusted {
            Darwin.exit(1)
        }
    }
}
