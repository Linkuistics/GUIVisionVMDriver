import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("ConnectionSpec")
struct ConnectionSpecTests {

    // MARK: - Platform

    @Test func platformRawValues() {
        #expect(Platform.macos.rawValue == "macos")
        #expect(Platform.windows.rawValue == "windows")
        #expect(Platform.linux.rawValue == "linux")
    }

    @Test func platformDecodesFromJSON() throws {
        let json = Data(#""windows""#.utf8)
        let platform = try JSONDecoder().decode(Platform.self, from: json)
        #expect(platform == .windows)
    }

    // MARK: - VNCSpec

    @Test func vncSpecDefaults() {
        let spec = VNCSpec(host: "myhost")
        #expect(spec.host == "myhost")
        #expect(spec.port == 5900)
        #expect(spec.password == nil)
    }

    @Test func vncSpecCustomPort() {
        let spec = VNCSpec(host: "myhost", port: 5901, password: "secret")
        #expect(spec.port == 5901)
        #expect(spec.password == "secret")
    }

    // MARK: - AgentSpec

    @Test func agentSpecDefaults() {
        let spec = AgentSpec(host: "myhost")
        #expect(spec.host == "myhost")
        #expect(spec.port == 8648)
    }

    @Test func agentSpecCustomPort() {
        let spec = AgentSpec(host: "myhost", port: 9000)
        #expect(spec.port == 9000)
    }

    // MARK: - ConnectionSpec JSON decoding

    @Test func decodesFullSpec() throws {
        let json = """
        {
            "vnc": { "host": "localhost", "port": 5900, "password": "abc123" },
            "agent": { "host": "localhost", "port": 8648 },
            "platform": "windows"
        }
        """
        let spec = try JSONDecoder().decode(ConnectionSpec.self, from: Data(json.utf8))

        #expect(spec.vnc.host == "localhost")
        #expect(spec.vnc.port == 5900)
        #expect(spec.vnc.password == "abc123")
        #expect(spec.agent?.host == "localhost")
        #expect(spec.agent?.port == 8648)
        #expect(spec.platform == .windows)
    }

    @Test func decodesMinimalSpec() throws {
        let json = """
        { "vnc": { "host": "192.168.1.100", "port": 5901 } }
        """
        let spec = try JSONDecoder().decode(ConnectionSpec.self, from: Data(json.utf8))

        #expect(spec.vnc.host == "192.168.1.100")
        #expect(spec.vnc.port == 5901)
        #expect(spec.agent == nil)
        #expect(spec.platform == nil)
    }

    // MARK: - CLI endpoint parsing

    @Test func parsesVNCEndpoint() throws {
        let spec = try ConnectionSpec.from(vnc: "myhost:5901")
        #expect(spec.vnc.host == "myhost")
        #expect(spec.vnc.port == 5901)
    }

    @Test func parsesVNCEndpointDefaultPort() throws {
        let spec = try ConnectionSpec.from(vnc: "myhost")
        #expect(spec.vnc.host == "myhost")
        #expect(spec.vnc.port == 5900)
    }

    @Test func parsesAgentEndpoint() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", agent: "myhost:8648")
        #expect(spec.agent?.host == "myhost")
        #expect(spec.agent?.port == 8648)
    }

    @Test func parsesAgentEndpointDefaultPort() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", agent: "10.0.0.1")
        #expect(spec.agent?.host == "10.0.0.1")
        #expect(spec.agent?.port == 8648)
    }

    @Test func parsesPlatform() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", platform: "macos")
        #expect(spec.platform == .macos)
    }

    @Test func rejectsInvalidPlatform() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: "localhost", platform: "android")
        }
    }

    @Test func rejectsEmptyHost() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: ":5900")
        }
    }

    @Test func rejectsInvalidPort() {
        #expect(throws: ConnectionSpecError.self) {
            try ConnectionSpec.from(vnc: "localhost:99999")
        }
    }

    @Test func encodesAndDecodesRoundtrip() throws {
        let original = ConnectionSpec(
            vnc: VNCSpec(host: "10.0.0.5", port: 5902, password: "secret"),
            agent: AgentSpec(host: "10.0.0.5", port: 8648),
            platform: .linux
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionSpec.self, from: data)
        #expect(decoded.vnc.host == original.vnc.host)
        #expect(decoded.vnc.port == original.vnc.port)
        #expect(decoded.vnc.password == original.vnc.password)
        #expect(decoded.agent?.host == original.agent?.host)
        #expect(decoded.agent?.port == original.agent?.port)
        #expect(decoded.platform == original.platform)
    }
}
