import Foundation
import Darwin
import GUIVisionAgentProtocol

enum JSONOutput {
    static func write<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(value)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } catch {
            fputs("guivision-agent: JSON encoding failed: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    static func error(_ message: String, details: String? = nil) -> Never {
        let response = ErrorResponse(error: message, details: details)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(response),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
        Darwin.exit(1)
    }
}
