import ArgumentParser
import Foundation
import GUIVisionVMDriver

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
            let matches = try await client.ocr(find: text)

            if !matches.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(matches)
                print(String(data: data, encoding: .utf8)!)
                return
            }

            // No match — if we have a timeout, poll; otherwise fail immediately.
            if let deadline, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }

            if text != nil {
                throw ValidationError("Text '\(text!)' not found on screen")
            } else {
                // No search term, just return empty
                print("[]")
                return
            }
        }
    }
}
