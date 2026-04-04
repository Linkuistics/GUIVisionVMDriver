import Testing
import Foundation
@testable import GUIVisionVMDriver
import GUIVisionAgentProtocol

@Suite("AgentClient")
struct AgentClientTests {

    // MARK: - Binary path

    @Test func defaultBinaryPath() {
        #expect(AgentClient.defaultBinaryPath == "/usr/local/bin/guivision-agent")
    }

    // MARK: - Command construction

    @Test func buildCommandNoArgs() {
        let cmd = AgentClient.buildCommand(
            binaryPath: "/usr/local/bin/guivision-agent",
            subcommand: "health",
            args: []
        )
        #expect(cmd == "/usr/local/bin/guivision-agent health")
    }

    @Test func buildCommandWithArgs() {
        let cmd = AgentClient.buildCommand(
            binaryPath: "/usr/local/bin/guivision-agent",
            subcommand: "snapshot",
            args: ["--mode", "interact", "--window", "Settings"]
        )
        #expect(cmd == "/usr/local/bin/guivision-agent snapshot --mode interact --window Settings")
    }

    @Test func buildCommandCustomBinaryPath() {
        let cmd = AgentClient.buildCommand(
            binaryPath: "/opt/bin/guivision-agent",
            subcommand: "windows",
            args: []
        )
        #expect(cmd == "/opt/bin/guivision-agent windows")
    }

    // MARK: - Response parsing

    @Test func parseSnapshotResponse() throws {
        let json = """
        {
          "windows": [
            {
              "title": "Settings",
              "windowType": "standard",
              "sizeWidth": 800,
              "sizeHeight": 600,
              "positionX": 100,
              "positionY": 200,
              "appName": "System Preferences",
              "focused": true
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let response = try AgentClient.parseResponse(SnapshotResponse.self, from: data)
        #expect(response.windows.count == 1)
        #expect(response.windows[0].title == "Settings")
        #expect(response.windows[0].appName == "System Preferences")
        #expect(response.windows[0].focused == true)
    }

    @Test func parseActionResponse() throws {
        let json = #"{"success": true, "message": "Pressed OK"}"#
        let data = Data(json.utf8)
        let response = try AgentClient.parseResponse(ActionResponse.self, from: data)
        #expect(response.success == true)
        #expect(response.message == "Pressed OK")
    }

    @Test func parseResponseThrowsOnInvalidJSON() {
        let data = Data("not json".utf8)
        #expect(throws: AgentClientError.self) {
            try AgentClient.parseResponse(SnapshotResponse.self, from: data)
        }
    }

    // MARK: - Error parsing

    @Test func parseErrorFromStderrJSON() {
        let stderr = #"{"error": "element not found", "details": "No button labelled OK"}"#
        let error = AgentClient.parseError(stdout: "", stderr: stderr, exitCode: 1)
        guard case .agentError(let message, let details) = error else {
            Issue.record("Expected agentError, got \(error)")
            return
        }
        #expect(message == "element not found")
        #expect(details == "No button labelled OK")
    }

    @Test func parseErrorFromStdoutJSON() {
        // Some subcommands write JSON to stdout even on error
        let stdout = #"{"error": "window not found", "details": nil}"#
        // This won't parse as valid JSON (nil is not JSON) — fall back to raw message
        let error = AgentClient.parseError(stdout: stdout, stderr: "", exitCode: 2)
        guard case .agentError(let message, _) = error else {
            Issue.record("Expected agentError, got \(error)")
            return
        }
        #expect(message == "exit code 2")
    }

    @Test func parseErrorFallbackWhenNoJSON() {
        let error = AgentClient.parseError(stdout: "", stderr: "something went wrong", exitCode: 127)
        guard case .agentError(let message, let details) = error else {
            Issue.record("Expected agentError, got \(error)")
            return
        }
        #expect(message == "exit code 127")
        #expect(details == "something went wrong")
    }

    @Test func parseErrorNoOutputFallback() {
        let error = AgentClient.parseError(stdout: "", stderr: "", exitCode: 1)
        guard case .agentError(let message, let details) = error else {
            Issue.record("Expected agentError, got \(error)")
            return
        }
        #expect(message == "exit code 1")
        #expect(details == nil)
    }

    @Test func parseErrorWithStderrJSONNoDetails() {
        let stderr = #"{"error": "timeout"}"#
        let error = AgentClient.parseError(stdout: "", stderr: stderr, exitCode: 1)
        guard case .agentError(let message, let details) = error else {
            Issue.record("Expected agentError, got \(error)")
            return
        }
        #expect(message == "timeout")
        #expect(details == nil)
    }

    // MARK: - AgentClientError description

    @Test func agentErrorDescriptionWithDetails() {
        let error = AgentClientError.agentError("element not found", details: "No match")
        #expect(error.errorDescription == "Agent error: element not found — No match")
    }

    @Test func agentErrorDescriptionWithoutDetails() {
        let error = AgentClientError.agentError("timeout", details: nil)
        #expect(error.errorDescription == "Agent error: timeout")
    }

    @Test func decodingFailedDescription() {
        let error = AgentClientError.decodingFailed("missing key 'windows'")
        #expect(error.errorDescription?.hasPrefix("Failed to decode agent response:") == true)
    }
}
