import ArgumentParser
import GUIVisionVMDriver

struct ScreenSizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen-size",
        abstract: "Query the VNC display dimensions"
    )

    @OptionGroup var connection: ConnectionOptions

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        guard let size = await capture.screenSize() else {
            throw ValidationError("Could not determine screen size")
        }
        print("\(Int(size.width))x\(Int(size.height))")
    }
}
