import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("ServerClient")
struct ServerClientTests {

    // MARK: - Socket path format

    @Test func socketPathIsUnderTmp() {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let path = ServerClient.socketPath(for: spec)
        #expect(path.hasPrefix("/tmp/guivision-"))
        #expect(path.hasSuffix(".sock"))
    }

    @Test func socketPathHexSegment() {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let path = ServerClient.socketPath(for: spec)
        // Extract the hex segment between "guivision-" and ".sock"
        let stripped = path
            .replacingOccurrences(of: "/tmp/guivision-", with: "")
            .replacingOccurrences(of: ".sock", with: "")
        #expect(stripped.count == 16)
        #expect(stripped.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Determinism

    @Test func sameSpecProducesSamePath() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.1", port: 5901, password: "pass"))
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.1", port: 5901, password: "pass"))
        #expect(ServerClient.socketPath(for: spec1) == ServerClient.socketPath(for: spec2))
    }

    @Test func sameSpecWithSSHProducesSamePath() {
        let ssh = SSHSpec(host: "10.0.0.1", port: 22, user: "admin", key: "~/.ssh/id_ed25519")
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.1", port: 5900), ssh: ssh, platform: .macos)
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.1", port: 5900), ssh: ssh, platform: .macos)
        #expect(ServerClient.socketPath(for: spec1) == ServerClient.socketPath(for: spec2))
    }

    // MARK: - Uniqueness

    @Test func differentHostProducesDifferentPath() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.1", port: 5900))
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "10.0.0.2", port: 5900))
        #expect(ServerClient.socketPath(for: spec1) != ServerClient.socketPath(for: spec2))
    }

    @Test func differentPortProducesDifferentPath() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5901))
        #expect(ServerClient.socketPath(for: spec1) != ServerClient.socketPath(for: spec2))
    }

    @Test func differentPasswordProducesDifferentPath() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900, password: "abc"))
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900, password: "xyz"))
        #expect(ServerClient.socketPath(for: spec1) != ServerClient.socketPath(for: spec2))
    }

    @Test func specWithSSHDiffersFromSpecWithout() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let spec2 = ConnectionSpec(
            vnc: VNCSpec(host: "localhost", port: 5900),
            ssh: SSHSpec(host: "localhost", port: 22, user: "admin")
        )
        #expect(ServerClient.socketPath(for: spec1) != ServerClient.socketPath(for: spec2))
    }

    @Test func differentPlatformProducesDifferentPath() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900), platform: .macos)
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900), platform: .linux)
        #expect(ServerClient.socketPath(for: spec1) != ServerClient.socketPath(for: spec2))
    }

    // MARK: - PID path

    @Test func pidPathFollowsSamePatternWithPidExtension() {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost", port: 5900))
        let socketPath = ServerClient.socketPath(for: spec)
        let pidPath = ServerClient.pidPath(for: spec)
        #expect(pidPath.hasPrefix("/tmp/guivision-"))
        #expect(pidPath.hasSuffix(".pid"))
        // Same hex segment as socket path
        let socketHex = socketPath
            .replacingOccurrences(of: "/tmp/guivision-", with: "")
            .replacingOccurrences(of: ".sock", with: "")
        let pidHex = pidPath
            .replacingOccurrences(of: "/tmp/guivision-", with: "")
            .replacingOccurrences(of: ".pid", with: "")
        #expect(socketHex == pidHex)
    }

    @Test func pidPathDifferentSpecsDifferentPaths() {
        let spec1 = ConnectionSpec(vnc: VNCSpec(host: "host-a", port: 5900))
        let spec2 = ConnectionSpec(vnc: VNCSpec(host: "host-b", port: 5900))
        #expect(ServerClient.pidPath(for: spec1) != ServerClient.pidPath(for: spec2))
    }
}
