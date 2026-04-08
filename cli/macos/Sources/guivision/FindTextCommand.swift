import ArgumentParser
import CoreGraphics
import Foundation
import GUIVisionVMDriver
import Vision

struct TextMatch: Codable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float
}

struct FindTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-text",
        abstract: "Find text on screen using Vision OCR"
    )

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Text to search for (case-insensitive substring match)")
    var text: String?

    @Option(name: .long, help: "Wait up to N seconds for the text to appear")
    var timeout: Int?

    mutating func run() async throws {
        let spec = try connection.resolve()
        let client = try await ServerClient.ensure(spec: spec)

        let deadline = timeout.map { Date().addingTimeInterval(Double($0)) }

        while true {
            let pngData = try await client.screenshot()
            let matches = recognizeText(in: pngData, find: text)

            if !matches.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(matches)
                print(String(data: data, encoding: .utf8)!)
                return
            }

            if let deadline, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }

            if text != nil {
                throw ValidationError("Text '\(text!)' not found on screen")
            } else {
                print("[]")
                return
            }
        }
    }

    private func recognizeText(in pngData: Data, find searchText: String?) -> [TextMatch] {
        guard let provider = CGDataProvider(data: pngData as CFData),
              let image = CGImage(
                  pngDataProviderSource: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return [] }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)

        var results: [TextMatch] = []
        for observation in observations {
            guard observation.confidence >= 0.5,
                  let candidate = observation.topCandidates(1).first else { continue }

            if let searchText,
               !candidate.string.localizedCaseInsensitiveContains(searchText) {
                continue
            }

            let box = observation.boundingBox
            results.append(TextMatch(
                text: candidate.string,
                x: box.origin.x * imageWidth,
                y: (1.0 - box.origin.y - box.height) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight,
                confidence: candidate.confidence
            ))
        }

        return results
    }
}
