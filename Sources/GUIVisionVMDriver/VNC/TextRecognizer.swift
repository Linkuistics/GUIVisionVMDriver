import CoreGraphics
import Foundation
import Vision

/// Result from Vision text recognition, with pixel coordinates (top-left origin).
public struct TextMatch: Codable, Sendable {
    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let confidence: Float
}

/// Recognizes text in a CGImage using Apple's Vision framework.
public enum TextRecognizer {

    /// Run OCR on the image and return all recognized text with bounding boxes.
    public static func recognizeText(
        in image: CGImage,
        minimumConfidence: Float = 0.5
    ) -> [TextMatch] {
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
            guard observation.confidence >= minimumConfidence,
                  let candidate = observation.topCandidates(1).first else { continue }

            // Vision uses normalized coordinates with bottom-left origin.
            // Convert to pixel coordinates with top-left origin.
            let box = observation.boundingBox
            let x = box.origin.x * imageWidth
            let y = (1.0 - box.origin.y - box.height) * imageHeight
            let width = box.width * imageWidth
            let height = box.height * imageHeight

            results.append(TextMatch(
                text: candidate.string,
                x: x, y: y, width: width, height: height,
                confidence: candidate.confidence
            ))
        }

        return results
    }
}
