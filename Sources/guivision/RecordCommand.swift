import ArgumentParser
import Foundation
import GUIVisionVMDriver

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record VNC screen to a video file"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "recording.mp4"

    @Option(name: .long, help: "Frames per second")
    var fps: Int = 30

    @Option(name: .long, help: "Duration in seconds (0 = until Ctrl+C)")
    var duration: Int = 0

    @Option(name: .long, help: "Crop region as x,y,width,height")
    var region: String?

    mutating func run() async throws {
        let spec = try connection.resolve()

        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()

        guard let screenSize = await capture.screenSize() else {
            throw ValidationError("Could not determine screen size")
        }

        let cropRegion: CGRect?
        if let regionStr = region {
            let parts = regionStr.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                throw ValidationError("Region must be x,y,width,height")
            }
            cropRegion = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else {
            cropRegion = nil
        }

        let recordWidth = Int(cropRegion?.width ?? screenSize.width)
        let recordHeight = Int(cropRegion?.height ?? screenSize.height)

        let config = StreamingCaptureConfig(width: recordWidth, height: recordHeight, fps: fps)
        let recorder = StreamingCapture()
        try await recorder.start(outputPath: output, config: config)

        print("Recording to \(output) at \(fps) fps (\(recordWidth)x\(recordHeight))...")
        if duration > 0 {
            print("Duration: \(duration)s")
        } else {
            print("Press Ctrl+C to stop")
        }

        let interval = Duration.milliseconds(1000 / fps)
        // Use a very large duration (~100 years) when no duration is specified
        let effectiveDuration = duration > 0 ? Duration.seconds(duration) : Duration.seconds(100 * 365 * 24 * 3600)
        let deadline = ContinuousClock.now + effectiveDuration

        while ContinuousClock.now < deadline {
            if let image = try? await capture.captureImage(region: cropRegion) {
                try? await recorder.appendFrame(image)
            }
            try await Task.sleep(for: interval)
        }

        try await recorder.stop()
        await capture.disconnect()
        print("Recording saved to \(output)")
    }
}
