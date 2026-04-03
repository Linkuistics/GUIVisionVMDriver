import CryptoKit
import Darwin
import Foundation

// MARK: - Transport errors

public enum ServerClientError: Error, Sendable {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
}

/// Client-side handle for a per-`ConnectionSpec` server instance.
///
/// This type will be expanded in later tasks (Tasks 6 and 7) with HTTP
/// transport and auto-start logic. For now it only exposes the static
/// socket/PID path computation helpers.
public enum ServerClient {

    // MARK: - Path computation

    /// Returns the Unix domain socket path for the server that handles `spec`.
    ///
    /// The path is deterministic: given the same `ConnectionSpec` value, every
    /// independent CLI invocation will compute the same path and therefore find
    /// the same server process.
    ///
    /// Algorithm:
    /// 1. JSON-encode `spec` with `.sortedKeys` so key order is canonical.
    /// 2. SHA-256 hash the UTF-8 bytes.
    /// 3. Hex-encode the digest and take the first 16 characters.
    /// 4. Return `/tmp/guivision-{hex}.sock`.
    public static func socketPath(for spec: ConnectionSpec) -> String {
        "/tmp/guivision-\(hexPrefix(for: spec)).sock"
    }

    /// Returns the PID-file path that accompanies the socket for `spec`.
    ///
    /// Follows the same naming convention as `socketPath(for:)`, replacing
    /// the `.sock` extension with `.pid`.
    public static func pidPath(for spec: ConnectionSpec) -> String {
        "/tmp/guivision-\(hexPrefix(for: spec)).pid"
    }

    // MARK: - HTTP transport

    /// Send a single HTTP request to the server socket for `socketPath` and
    /// return the parsed response.
    ///
    /// Connects to the Unix domain socket, writes the serialized request,
    /// reads the full response (headers + body), and closes the connection.
    public static func send(_ request: HTTPRequest, to socketPath: String) async throws -> HTTPResponse {
        // Connect on a background thread so we don't block the cooperative pool.
        let fd = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            let thread = Thread {
                // Create the socket.
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    continuation.resume(throwing: ServerClientError.socketCreateFailed(errno))
                    return
                }

                // Build sockaddr_un and connect.
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                        _ = strlcpy(cptr, socketPath, 104)
                    }
                }
                let result = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                        Darwin.connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else {
                    Darwin.close(fd)
                    continuation.resume(throwing: ServerClientError.connectFailed(errno))
                    return
                }

                continuation.resume(returning: fd)
            }
            thread.start()
        }

        defer { Darwin.close(fd) }

        // Write the serialized request.
        let requestData = HTTPParser.serializeRequest(request)
        await writeAll(fd: fd, data: requestData)

        // Read the response, accumulating until we can parse it.
        var buffer = Data()
        let chunkSize = 65536
        let headerSeparator = Data("\r\n\r\n".utf8)

        while true {
            let chunk = await readChunk(fd: fd, maxBytes: chunkSize)
            if let data = chunk {
                buffer.append(data)
            }

            // Once we have the full header block and the declared body bytes, parse.
            if buffer.range(of: headerSeparator) != nil {
                // Check if we have all body bytes declared by Content-Length.
                if let response = try? HTTPParser.parseResponse(from: buffer) {
                    return response
                }
            }

            // Hit EOF/error and still cannot parse.
            if chunk == nil {
                // Try one last parse in case the response had no body.
                return try HTTPParser.parseResponse(from: buffer)
            }
        }
    }

    // MARK: - Private socket helpers

    /// Read up to `maxBytes` from `fd` on a background thread. Returns `nil` on EOF or error.
    private static func readChunk(fd: Int32, maxBytes: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                var buf = [UInt8](repeating: 0, count: maxBytes)
                let n = Darwin.read(fd, &buf, maxBytes)
                if n > 0 {
                    continuation.resume(returning: Data(buf[0..<n]))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            thread.start()
        }
    }

    /// Write all bytes of `data` to `fd` on a background thread, looping until complete or error.
    private static func writeAll(fd: Int32, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                data.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else {
                        continuation.resume()
                        return
                    }
                    var offset = 0
                    while offset < data.count {
                        let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
                continuation.resume()
            }
            thread.start()
        }
    }

    // MARK: - Private helpers

    /// Computes the 16-character lowercase hex prefix used in both path kinds.
    private static func hexPrefix(for spec: ConnectionSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // JSONEncoder.encode(_:) only throws for types that implement custom
        // encoding with errors; ConnectionSpec is a plain Codable struct and
        // will never throw in practice.
        let data = (try? encoder.encode(spec)) ?? Data()
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
