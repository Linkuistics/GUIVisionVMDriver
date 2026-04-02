import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("SSHClient")
struct SSHClientTests {

    @Test func initFromSSHSpec() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin", key: "~/.ssh/id_ed25519")
        let client = SSHClient(spec: spec)
        #expect(client.host == "myhost")
        #expect(client.port == 2222)
        #expect(client.user == "admin")
    }

    @Test func initFromConnectionSpec() throws {
        let spec = try ConnectionSpec.from(vnc: "localhost", ssh: "root@10.0.0.1:2222")
        let client = try SSHClient(connectionSpec: spec)
        #expect(client.host == "10.0.0.1")
        #expect(client.user == "root")
        #expect(client.port == 2222)
    }

    @Test func initFailsWithoutSSHSpec() {
        let spec = ConnectionSpec(vnc: VNCSpec(host: "localhost"))
        #expect(throws: SSHClientError.self) {
            try SSHClient(connectionSpec: spec)
        }
    }

    @Test func controlPathIsUnique() {
        let spec1 = SSHSpec(host: "host1", user: "user1")
        let spec2 = SSHSpec(host: "host2", user: "user2")
        let client1 = SSHClient(spec: spec1)
        let client2 = SSHClient(spec: spec2)
        #expect(client1.controlPath != client2.controlPath)
    }

    @Test func controlPathIsDeterministic() {
        let spec = SSHSpec(host: "myhost", port: 22, user: "admin")
        let client1 = SSHClient(spec: spec)
        let client2 = SSHClient(spec: spec)
        #expect(client1.controlPath == client2.controlPath)
    }

    @Test func buildsSSHCommandWithKey() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin", key: "~/.ssh/id_ed25519")
        let client = SSHClient(spec: spec)
        let args = client.sshArguments(for: "echo hello")
        #expect(args.contains("-p"))
        #expect(args.contains("2222"))
        #expect(args.contains("-i"))
        #expect(args.contains("~/.ssh/id_ed25519"))
        #expect(args.contains("admin@myhost"))
        #expect(args.last == "echo hello")
    }

    @Test func buildsSSHCommandWithoutKey() {
        let spec = SSHSpec(host: "myhost", user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.sshArguments(for: "ls")
        #expect(!args.contains("-i"))
        #expect(args.contains("admin@myhost"))
    }

    @Test func buildsSCPUploadArgs() {
        let spec = SSHSpec(host: "myhost", port: 2222, user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.scpUploadArguments(localPath: "/tmp/file.txt", remotePath: "/home/admin/file.txt")
        #expect(args.contains("-P"))
        #expect(args.contains("2222"))
        #expect(args.contains("/tmp/file.txt"))
        #expect(args.last == "admin@myhost:/home/admin/file.txt")
    }

    @Test func buildsSCPDownloadArgs() {
        let spec = SSHSpec(host: "myhost", user: "admin")
        let client = SSHClient(spec: spec)
        let args = client.scpDownloadArguments(remotePath: "/var/log/app.log", localPath: "/tmp/app.log")
        #expect(args.contains("admin@myhost:/var/log/app.log"))
        #expect(args.last == "/tmp/app.log")
    }
}
