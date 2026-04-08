import ArgumentParser
import CoreGraphics
import Foundation
import Vision

struct TextDetection: Codable, Sendable {
    let text: String
    let bounds: Bounds
    let confidence: Float

    struct Bounds: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

@main
struct OCRAnalyzerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guivision-ocr",
        abstract: "Extract text from an image using Apple Vision OCR"
    )

    @Argument(help: "Path to the input image (PNG or JPEG)")
    var imagePath: String

    @Option(name: .long, help: "Recognition level: accurate or fast")
    var recognitionLevel: String = "accurate"

    @Option(name: .long, help: "Comma-separated list of languages (BCP 47 codes)")
    var languages: String = "en"

    @Option(name: .long, help: "Minimum confidence threshold (0.0 to 1.0)")
    var minConfidence: Float = 0.5

    mutating func run() throws {
        let url = URL(fileURLWithPath: imagePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("Image file not found: \(imagePath)")
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ValidationError("Failed to load image: \(imagePath)")
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()

        switch recognitionLevel.lowercased() {
        case "accurate":
            request.recognitionLevel = .accurate
        case "fast":
            request.recognitionLevel = .fast
        default:
            throw ValidationError("Invalid recognition level: \(recognitionLevel). Use 'accurate' or 'fast'.")
        }

        let languageList = languages.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        request.recognitionLanguages = languageList
        request.usesLanguageCorrection = true

        try handler.perform([request])

        guard let observations = request.results else {
            try printJSON([TextDetection]())
            return
        }

        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)

        var detections: [TextDetection] = []
        for observation in observations {
            guard observation.confidence >= minConfidence,
                  let candidate = observation.topCandidates(1).first else { continue }

            let box = observation.boundingBox
            // Vision uses bottom-left origin with normalized coordinates.
            // Convert to top-left origin with pixel coordinates.
            let pixelX = box.origin.x * imageWidth
            let pixelY = (1.0 - box.origin.y - box.height) * imageHeight
            let pixelWidth = box.width * imageWidth
            let pixelHeight = box.height * imageHeight

            detections.append(TextDetection(
                text: candidate.string,
                bounds: TextDetection.Bounds(
                    x: pixelX,
                    y: pixelY,
                    width: pixelWidth,
                    height: pixelHeight
                ),
                confidence: candidate.confidence
            ))
        }

        try printJSON(detections)
    }

    private func printJSON(_ detections: [TextDetection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(detections)
        print(String(data: data, encoding: .utf8)!)
    }
}
