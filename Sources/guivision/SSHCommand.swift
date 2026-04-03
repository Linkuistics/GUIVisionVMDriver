import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct SSHCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Execute commands and transfer files over SSH",
        subcommands: [
            ExecCommand.self,
            UploadCommand.self,
            DownloadCommand.self,
        ]
    )
}

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Execute a remote command")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Command to execute")
    var command: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try await ServerClient.ensure(spec: spec)
        let result = try await client.sshExec(command)
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        if !result.succeeded {
            throw ExitCode(result.exitCode)
        }
    }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload a file")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Local file path")
    var localPath: String

    @Argument(help: "Remote file path")
    var remotePath: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try await ServerClient.ensure(spec: spec)
        try await client.sshUpload(localPath: localPath, remotePath: remotePath)
        print("Uploaded \(localPath) → \(remotePath)")
    }
}

struct DownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "download", abstract: "Download a file")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Remote file path")
    var remotePath: String

    @Argument(help: "Local file path")
    var localPath: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try await ServerClient.ensure(spec: spec)
        try await client.sshDownload(remotePath: remotePath, localPath: localPath)
        print("Downloaded \(remotePath) → \(localPath)")
    }
}
