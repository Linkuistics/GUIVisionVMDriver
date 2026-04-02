import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the VNC server"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .shortAndLong, help: "Output file path (default: screenshot.png)")
    var output: String = "screenshot.png"

    @Option(name: .long, help: "Crop region as x,y,width,height")
    var region: String?

    mutating func run() async throws {
        let spec = try connection.resolve()

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        let cropRegion: CGRect?
        if let regionStr = region {
            cropRegion = try parseRegion(regionStr)
        } else {
            cropRegion = nil
        }

        let pngData = try await capture.screenshot(region: cropRegion)
        let url = URL(fileURLWithPath: output)
        try pngData.write(to: url)
        print("Screenshot saved to \(output) (\(pngData.count) bytes)")
    }

    private func parseRegion(_ str: String) throws -> CGRect {
        let parts = str.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else {
            throw ValidationError("Region must be x,y,width,height (e.g. 0,0,800,600)")
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
