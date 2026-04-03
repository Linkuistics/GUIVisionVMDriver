import Foundation

// MARK: - Types

/// A parsed HTTP/1.1 request.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let body: Data?

    public init(method: String, path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }
}

/// An HTTP/1.1 response to serialize and send.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let contentType: String
    public let body: Data

    public init(statusCode: Int, contentType: String, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

// MARK: - Errors

public enum HTTPParserError: Error, Sendable {
    case missingHeaderBlock
    case malformedRequestLine(String)
}

// MARK: - Parser

public enum HTTPParser: Sendable {

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    /// Parse a raw HTTP/1.1 request from bytes.
    /// Reads headers up to `\r\n\r\n`, then reads `Content-Length` bytes for the body.
    public static func parseRequest(_ data: Data) throws -> HTTPRequest {
        guard let separatorRange = data.range(of: headerSeparator) else {
            throw HTTPParserError.missingHeaderBlock
        }

        let headerBlock = data[data.startIndex..<separatorRange.lowerBound]
        let headerText = String(decoding: headerBlock, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        // Parse request line
        let requestLine = lines[0]
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw HTTPParserError.malformedRequestLine(requestLine)
        }
        let method = String(parts[0])
        let path = String(parts[1])

        // Parse Content-Length header
        var contentLength: Int? = nil
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            }
        }

        // Read body if Content-Length present
        var body: Data? = nil
        if let length = contentLength, length > 0 {
            let bodyStart = separatorRange.upperBound
            let bodyEnd = data.index(bodyStart, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            body = Data(data[bodyStart..<bodyEnd])
        }

        return HTTPRequest(method: method, path: path, body: body)
    }

    /// Serialize an HTTP/1.1 response to bytes.
    /// Format: `HTTP/1.1 {status} {reason}\r\nContent-Type: ...\r\nContent-Length: ...\r\nConnection: close\r\n\r\n{body}`
    public static func serializeResponse(_ response: HTTPResponse) -> Data {
        let reason = reasonPhrase(for: response.statusCode)
        let header = "HTTP/1.1 \(response.statusCode) \(reason)\r\n" +
            "Content-Type: \(response.contentType)\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var result = Data(header.utf8)
        result.append(response.body)
        return result
    }

    // MARK: - Private

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}
