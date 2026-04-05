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
    case bodyIncomplete
    case malformedRequestLine(String)
    case malformedStatusLine(String)
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

    /// Serialize an HTTP/1.1 request to bytes.
    /// Format: `METHOD PATH HTTP/1.1\r\nContent-Length: N\r\nConnection: close\r\n\r\nbody`
    /// For requests with no body, Content-Length is omitted.
    public static func serializeRequest(_ request: HTTPRequest) -> Data {
        let bodyData = request.body ?? Data()
        var header = "\(request.method) \(request.path) HTTP/1.1\r\n"
        if !bodyData.isEmpty {
            header += "Content-Length: \(bodyData.count)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var result = Data(header.utf8)
        result.append(bodyData)
        return result
    }

    /// Parse a raw HTTP/1.1 response from bytes.
    /// Reads the status line for the status code, scans headers for Content-Type,
    /// reads `Content-Length` bytes for the body.
    public static func parseResponse(from data: Data) throws -> HTTPResponse {
        guard let separatorRange = data.range(of: headerSeparator) else {
            throw HTTPParserError.missingHeaderBlock
        }

        let headerBlock = data[data.startIndex..<separatorRange.lowerBound]
        let headerText = String(decoding: headerBlock, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        // Parse status line: HTTP/1.1 {code} {reason}
        let statusLine = lines[0]
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw HTTPParserError.malformedStatusLine(statusLine)
        }

        // Scan headers for Content-Type and Content-Length
        var contentType = "application/octet-stream"
        var contentLength: Int? = nil
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-type:") {
                contentType = line.dropFirst("content-type:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            }
        }

        // Read body
        let bodyStart = separatorRange.upperBound
        let body: Data
        if let length = contentLength, length > 0 {
            let available = data.distance(from: bodyStart, to: data.endIndex)
            guard available >= length else {
                throw HTTPParserError.bodyIncomplete
            }
            let bodyEnd = data.index(bodyStart, offsetBy: length)
            body = Data(data[bodyStart..<bodyEnd])
        } else {
            body = Data()
        }

        return HTTPResponse(statusCode: statusCode, contentType: contentType, body: body)
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
