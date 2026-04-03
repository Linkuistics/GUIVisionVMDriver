import Testing
import Foundation
@testable import GUIVisionVMDriver

@Suite("HTTPParser")
struct HTTPParserTests {

    // MARK: - Request Parsing

    @Test func parsesGETWithNoBody() throws {
        let raw = "GET /screenshot HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = try HTTPParser.parseRequest(Data(raw.utf8))
        #expect(request.method == "GET")
        #expect(request.path == "/screenshot")
        #expect(request.body == nil)
    }

    @Test func parsesPOSTWithJSONBody() throws {
        let body = #"{"key":"value"}"#
        let raw = "POST /run HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try HTTPParser.parseRequest(Data(raw.utf8))
        #expect(request.method == "POST")
        #expect(request.path == "/run")
        #expect(request.body == Data(body.utf8))
    }

    @Test func parsesPOSTMissingContentLengthDefaultsToNoBody() throws {
        let raw = "POST /run HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"
        let request = try HTTPParser.parseRequest(Data(raw.utf8))
        #expect(request.method == "POST")
        #expect(request.path == "/run")
        #expect(request.body == nil)
    }

    @Test func rejectsMalformedRequestLine() {
        let raw = "BADLINE\r\n\r\n"
        #expect(throws: HTTPParserError.self) {
            try HTTPParser.parseRequest(Data(raw.utf8))
        }
    }

    @Test func rejectsMissingHeaderBlock() {
        // No \r\n\r\n separator
        let raw = "GET /screenshot HTTP/1.1\r\nHost: localhost"
        #expect(throws: HTTPParserError.self) {
            try HTTPParser.parseRequest(Data(raw.utf8))
        }
    }

    // MARK: - Response Serialization

    @Test func serializes200WithJSONBody() {
        let body = Data(#"{"ok":true}"#.utf8)
        let response = HTTPResponse(statusCode: 200, contentType: "application/json", body: body)
        let serialized = HTTPParser.serializeResponse(response)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(serialized.suffix(body.count) == body)
    }

    @Test func serializes200WithPNGBody() {
        let body = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        let response = HTTPResponse(statusCode: 200, contentType: "image/png", body: body)
        let serialized = HTTPParser.serializeResponse(response)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.contains("Content-Type: image/png\r\n"))
        #expect(text.contains("Content-Length: 4\r\n"))
        #expect(serialized.suffix(body.count) == body)
    }

    @Test func serializes400WithErrorJSON() {
        let body = Data(#"{"error":"bad request"}"#.utf8)
        let response = HTTPResponse(statusCode: 400, contentType: "application/json", body: body)
        let serialized = HTTPParser.serializeResponse(response)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test func serializes404WithErrorJSON() {
        let body = Data(#"{"error":"not found"}"#.utf8)
        let response = HTTPResponse(statusCode: 404, contentType: "application/json", body: body)
        let serialized = HTTPParser.serializeResponse(response)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test func responseHeaderAndBodyAreCorrectlySeparated() {
        let body = Data("hello".utf8)
        let response = HTTPResponse(statusCode: 200, contentType: "text/plain", body: body)
        let serialized = HTTPParser.serializeResponse(response)
        // Find \r\n\r\n separator
        let separator = Data("\r\n\r\n".utf8)
        let separatorRange = serialized.range(of: separator)
        #expect(separatorRange != nil)
        if let range = separatorRange {
            let afterSeparator = serialized[range.upperBound...]
            #expect(afterSeparator == body)
        }
    }

    // MARK: - Request Serialization

    @Test func serializesGETWithNoBody() {
        let request = HTTPRequest(method: "GET", path: "/screenshot")
        let serialized = HTTPParser.serializeRequest(request)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.hasPrefix("GET /screenshot HTTP/1.1\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
        // No body bytes after the header separator
        let separator = Data("\r\n\r\n".utf8)
        if let range = serialized.range(of: separator) {
            #expect(range.upperBound == serialized.endIndex)
        }
    }

    @Test func serializesGETOmitsContentLength() {
        let request = HTTPRequest(method: "GET", path: "/health")
        let serialized = HTTPParser.serializeRequest(request)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(!text.contains("Content-Length:"))
    }

    @Test func serializesPOSTWithJSONBody() {
        let body = Data(#"{"action":"click"}"#.utf8)
        let request = HTTPRequest(method: "POST", path: "/click", body: body)
        let serialized = HTTPParser.serializeRequest(request)
        let text = String(decoding: serialized, as: UTF8.self)
        #expect(text.hasPrefix("POST /click HTTP/1.1\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(serialized.suffix(body.count) == body)
    }

    // MARK: - Response Parsing

    @Test func parses200WithJSONBody() throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + String(decoding: body, as: UTF8.self)
        let response = try HTTPParser.parseResponse(from: Data(raw.utf8))
        #expect(response.statusCode == 200)
        #expect(response.contentType == "application/json")
        #expect(response.body == body)
    }

    @Test func parses200WithPNGBody() throws {
        let body = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
        var raw = Data(header.utf8)
        raw.append(body)
        let response = try HTTPParser.parseResponse(from: raw)
        #expect(response.statusCode == 200)
        #expect(response.contentType == "image/png")
        #expect(response.body == body)
    }

    @Test func parses404ErrorResponse() throws {
        let body = Data(#"{"error":"not found"}"#.utf8)
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + String(decoding: body, as: UTF8.self)
        let response = try HTTPParser.parseResponse(from: Data(raw.utf8))
        #expect(response.statusCode == 404)
        #expect(response.contentType == "application/json")
        #expect(response.body == body)
    }

    @Test func parseResponseRejectsMissingHeaderBlock() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain"
        #expect(throws: HTTPParserError.self) {
            try HTTPParser.parseResponse(from: Data(raw.utf8))
        }
    }

    @Test func parseResponseRejectsMalformedStatusLine() {
        let raw = "NOTHTTP\r\n\r\n"
        #expect(throws: HTTPParserError.self) {
            try HTTPParser.parseResponse(from: Data(raw.utf8))
        }
    }
}
