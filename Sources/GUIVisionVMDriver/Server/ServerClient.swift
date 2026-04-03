import CoreGraphics
import CryptoKit
import Darwin
import Foundation

// MARK: - Transport errors

public enum ServerClientError: Error, Sendable {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
    case serverStartTimeout
    case serverStartFailed(String)
    case httpError(Int, String)
}

extension ServerClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let e):
            "Socket creation failed (errno \(e))"
        case .connectFailed(let e):
            "Connection refused (errno \(e))"
        case .serverStartTimeout:
            "Timed out waiting for server to become ready"
        case .serverStartFailed(let msg):
            "Server failed to start: \(msg)"
        case .httpError(let code, let msg):
            "HTTP \(code): \(msg)"
        }
    }
}

// MARK: - ServerClient

/// Client-side handle for a per-`ConnectionSpec` server instance.
///
/// Create instances via `ensure(spec:idleTimeout:)` which auto-starts the
/// server process if it isn't already running. Once you have a `ServerClient`
/// you can call the high-level API methods (screenshot, click, sshExec, …).
public struct ServerClient: Sendable {

    /// Unix domain socket path for this server instance.
    private let socketPath: String

    private init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Factory

    /// Return a `ServerClient` connected to the server for `spec`, starting
    /// the server process if it isn't already running.
    ///
    /// - Parameters:
    ///   - spec: The connection spec that identifies the target VM.
    ///   - idleTimeout: Seconds before an idle server self-terminates. Default 300.
    public static func ensure(
        spec: ConnectionSpec,
        idleTimeout: Int = 300
    ) async throws -> ServerClient {
        let path = Self.socketPath(for: spec)

        // Fast path: server is already up.
        if await isHealthy(socketPath: path) {
            return ServerClient(socketPath: path)
        }

        // Remove stale socket/PID files.
        let pidFilePath = Self.pidPath(for: spec)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: pidFilePath)

        // Locate the current executable.
        var execPath = CommandLine.arguments[0]
        if !execPath.hasPrefix("/") {
            let cwd = FileManager.default.currentDirectoryPath
            execPath = (cwd as NSString).appendingPathComponent(execPath)
        }
        execPath = (execPath as NSString).standardizingPath

        // JSON-encode the ConnectionSpec for --connect-json.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(spec)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ServerClientError.serverStartFailed("Could not encode ConnectionSpec as JSON")
        }

        // Spawn the server process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [
            "_server",
            "--connect-json", jsonString,
            "--idle-timeout", "\(idleTimeout)",
        ]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Let stderr inherit so launch errors surface in the terminal.
        process.standardError = FileHandle.standardError

        process.qualityOfService = .background

        do {
            try process.run()
        } catch {
            throw ServerClientError.serverStartFailed(error.localizedDescription)
        }

        // Wait for "ready\n" on stdout, with a 10-second timeout.
        let ready = await waitForReady(pipe: outPipe, timeoutSeconds: 10)
        guard ready else {
            process.terminate()
            throw ServerClientError.serverStartTimeout
        }

        // Final health check to confirm the socket is accepting connections.
        guard await isHealthy(socketPath: path) else {
            process.terminate()
            throw ServerClientError.serverStartFailed("Server reported ready but health check failed")
        }

        return ServerClient(socketPath: path)
    }

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

    /// Perform a GET /health and return true if status == 200.
    private static func isHealthy(socketPath: String) async -> Bool {
        let request = HTTPRequest(method: "GET", path: "/health")
        guard let response = try? await send(request, to: socketPath) else {
            return false
        }
        return response.statusCode == 200
    }

    /// Read lines from `pipe` until we see "ready" or time out.
    private static func waitForReady(pipe: Pipe, timeoutSeconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let handle = pipe.fileHandleForReading
                let deadline = Date(timeIntervalSinceNow: Double(timeoutSeconds))
                var accumulated = Data()

                while Date() < deadline {
                    var buf = [UInt8](repeating: 0, count: 256)
                    let n = Darwin.read(handle.fileDescriptor, &buf, 256)
                    if n > 0 {
                        accumulated.append(contentsOf: buf[0..<n])
                        if let text = String(data: accumulated, encoding: .utf8),
                           text.contains("ready") {
                            continuation.resume(returning: true)
                            return
                        }
                    } else if n == 0 {
                        // EOF — process exited before signalling ready.
                        break
                    }
                    // n < 0: EAGAIN or similar — spin briefly.
                    Thread.sleep(forTimeInterval: 0.05)
                }

                continuation.resume(returning: false)
            }
            thread.start()
        }
    }

    // MARK: - Response error checking

    /// Parse an error message from a JSON {"error":"..."} body.
    private func errorMessage(from response: HTTPResponse) -> String {
        struct ErrorBody: Decodable { let error: String }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: response.body) {
            return body.error
        }
        return String(data: response.body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
    }

    /// Throw `ServerClientError.httpError` if status is not 2xx.
    private func checkSuccess(_ response: HTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw ServerClientError.httpError(response.statusCode, errorMessage(from: response))
        }
    }

    // MARK: - JSON body construction

    /// Encode an `Encodable` value as JSON `Data`.
    private func jsonBody<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

// MARK: - High-level API

extension ServerClient {

    // MARK: Screen

    /// Capture a screenshot and return the raw PNG bytes.
    public func screenshot(region: CGRect? = nil) async throws -> Data {
        struct ScreenshotRequest: Encodable { let region: String? }
        let regionStr = region.map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height))" }
        let body = try jsonBody(ScreenshotRequest(region: regionStr))
        let request = HTTPRequest(method: "POST", path: "/screenshot", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
        return response.body
    }

    /// Return the current screen dimensions.
    public func screenSize() async throws -> CGSize {
        struct SizeResponse: Decodable { let width: Int; let height: Int }
        let request = HTTPRequest(method: "GET", path: "/screen-size")
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
        let parsed = try JSONDecoder().decode(SizeResponse.self, from: response.body)
        return CGSize(width: parsed.width, height: parsed.height)
    }

    // MARK: Keyboard

    /// Press a key (down + up) with optional modifiers.
    public func pressKey(_ key: String, modifiers: [String] = []) async throws {
        struct KeyRequest: Encodable { let key: String; let modifiers: [String] }
        let body = try jsonBody(KeyRequest(key: key, modifiers: modifiers))
        let request = HTTPRequest(method: "POST", path: "/input/key", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Send a key-down event.
    public func keyDown(_ key: String) async throws {
        struct KeyRequest: Encodable { let key: String }
        let body = try jsonBody(KeyRequest(key: key))
        let request = HTTPRequest(method: "POST", path: "/input/key-down", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Send a key-up event.
    public func keyUp(_ key: String) async throws {
        struct KeyRequest: Encodable { let key: String }
        let body = try jsonBody(KeyRequest(key: key))
        let request = HTTPRequest(method: "POST", path: "/input/key-up", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Type a string of text by synthesising key events for each character.
    public func typeText(_ text: String) async throws {
        struct TypeRequest: Encodable { let text: String }
        let body = try jsonBody(TypeRequest(text: text))
        let request = HTTPRequest(method: "POST", path: "/input/type", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    // MARK: Mouse

    /// Click at `(x, y)` with the given button and click count.
    public func click(x: Int, y: Int, button: String = "left", count: Int = 1) async throws {
        struct ClickRequest: Encodable { let x: Int; let y: Int; let button: String; let count: Int }
        let body = try jsonBody(ClickRequest(x: x, y: y, button: button, count: count))
        let request = HTTPRequest(method: "POST", path: "/input/click", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Send a mouse-button-down event.
    public func mouseDown(x: Int, y: Int, button: String = "left") async throws {
        struct MouseRequest: Encodable { let x: Int; let y: Int; let button: String }
        let body = try jsonBody(MouseRequest(x: x, y: y, button: button))
        let request = HTTPRequest(method: "POST", path: "/input/mouse-down", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Send a mouse-button-up event.
    public func mouseUp(x: Int, y: Int, button: String = "left") async throws {
        struct MouseRequest: Encodable { let x: Int; let y: Int; let button: String }
        let body = try jsonBody(MouseRequest(x: x, y: y, button: button))
        let request = HTTPRequest(method: "POST", path: "/input/mouse-up", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Move the mouse cursor to `(x, y)`.
    public func mouseMove(x: Int, y: Int) async throws {
        struct MoveRequest: Encodable { let x: Int; let y: Int }
        let body = try jsonBody(MoveRequest(x: x, y: y))
        let request = HTTPRequest(method: "POST", path: "/input/move", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Scroll at `(x, y)` by `(dx, dy)` units.
    public func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        struct ScrollRequest: Encodable { let x: Int; let y: Int; let dx: Int; let dy: Int }
        let body = try jsonBody(ScrollRequest(x: x, y: y, dx: dx, dy: dy))
        let request = HTTPRequest(method: "POST", path: "/input/scroll", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Drag from `(fromX, fromY)` to `(toX, toY)` using `button`, interpolating over `steps`.
    public func drag(
        fromX: Int, fromY: Int,
        toX: Int, toY: Int,
        button: String = "left",
        steps: Int = 10
    ) async throws {
        struct DragRequest: Encodable {
            let fromX: Int; let fromY: Int
            let toX: Int; let toY: Int
            let button: String; let steps: Int
        }
        let body = try jsonBody(DragRequest(fromX: fromX, fromY: fromY, toX: toX, toY: toY, button: button, steps: steps))
        let request = HTTPRequest(method: "POST", path: "/input/drag", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    // MARK: SSH

    /// Execute a remote shell command and return the result.
    public func sshExec(_ command: String, timeout: Int = 30) async throws -> SSHResult {
        struct ExecRequest: Encodable { let command: String; let timeout: Int }
        struct ExecResponse: Decodable { let exitCode: Int32; let stdout: String; let stderr: String }
        let body = try jsonBody(ExecRequest(command: command, timeout: timeout))
        let request = HTTPRequest(method: "POST", path: "/ssh/exec", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
        let parsed = try JSONDecoder().decode(ExecResponse.self, from: response.body)
        return SSHResult(exitCode: parsed.exitCode, stdout: parsed.stdout, stderr: parsed.stderr)
    }

    /// Upload a local file to the remote machine.
    public func sshUpload(localPath: String, remotePath: String) async throws {
        struct UploadRequest: Encodable { let localPath: String; let remotePath: String }
        let body = try jsonBody(UploadRequest(localPath: localPath, remotePath: remotePath))
        let request = HTTPRequest(method: "POST", path: "/ssh/upload", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Download a file from the remote machine to a local path.
    public func sshDownload(remotePath: String, localPath: String) async throws {
        struct DownloadRequest: Encodable { let remotePath: String; let localPath: String }
        let body = try jsonBody(DownloadRequest(remotePath: remotePath, localPath: localPath))
        let request = HTTPRequest(method: "POST", path: "/ssh/download", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    // MARK: Recording

    /// Start recording the screen to `output`.
    public func recordStart(
        output: String,
        fps: Int = 30,
        duration: Int,
        region: CGRect? = nil
    ) async throws {
        struct RecordRequest: Encodable {
            let output: String; let fps: Int; let duration: Int; let region: String?
        }
        let regionStr = region.map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height))" }
        let body = try jsonBody(RecordRequest(output: output, fps: fps, duration: duration, region: regionStr))
        let request = HTTPRequest(method: "POST", path: "/record/start", body: body)
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    /// Stop an active screen recording.
    public func recordStop() async throws {
        let request = HTTPRequest(method: "POST", path: "/record/stop")
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }

    // MARK: Lifecycle

    /// Ask the server to shut itself down.
    public func stop() async throws {
        let request = HTTPRequest(method: "POST", path: "/stop")
        let response = try await Self.send(request, to: socketPath)
        try checkSuccess(response)
    }
}
