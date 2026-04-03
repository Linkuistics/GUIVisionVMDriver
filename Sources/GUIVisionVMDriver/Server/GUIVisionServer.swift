import Darwin
import Foundation

// MARK: - Server errors

public enum ServerError: Error, Sendable {
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// The core server actor that routes HTTP requests and manages an idle timer.
///
/// The idle timer starts immediately on init. Each `handleRequest(_:)` call
/// cancels the current timer and starts a fresh one. When the timer fires
/// without a new request, the server shuts down.
///
/// Call `start(socketPath:pidPath:)` after init to bind the Unix socket and
/// begin accepting connections.
///
/// Handler methods are stubs in this task; real VNC/SSH integration comes in Task 5.
public actor GUIVisionServer {

    // MARK: - Properties

    private let spec: ConnectionSpec
    private let idleTimeout: Duration
    public let onShutdown: @Sendable () -> Void

    /// The currently pending idle timer task. Cancelled and replaced on every request.
    private var idleTimerTask: Task<Void, Never>?

    /// The background accept-loop task. Cancelled by `shutdown()`.
    private var acceptTask: Task<Void, Never>?

    /// Paths stored so `shutdown()` can remove them.
    private var currentSocketPath: String?
    private var currentPidPath: String?

    // MARK: - Init

    public init(
        spec: ConnectionSpec,
        idleTimeout: Duration,
        onShutdown: @escaping @Sendable () -> Void
    ) {
        self.spec = spec
        self.idleTimeout = idleTimeout
        self.onShutdown = onShutdown
        // Swift 6 strict concurrency: actor-isolated stored properties cannot be
        // assigned from within a Task closure in a nonisolated initializer.
        // We work around this by calling the onShutdown closure directly
        // (a captured value, not actor state), mirroring the original Task 3 pattern.
        // After init, armIdleTimer() calls self.shutdown() which is fully actor-isolated.
        let timeout = idleTimeout
        let shutdownCallback = onShutdown
        idleTimerTask = Task {
            do {
                try await Task.sleep(for: timeout)
                shutdownCallback()
            } catch {
                // Cancelled by a new request — nothing to do.
            }
        }
    }

    // MARK: - Networking

    /// Bind a Unix domain socket at `socketPath`, begin accepting connections,
    /// and write the PID file at `pidPath`.
    ///
    /// This method returns immediately; the accept loop runs in a background Task.
    public func start(socketPath: String, pidPath: String) throws {
        currentSocketPath = socketPath
        currentPidPath = pidPath

        // Remove any stale socket file from a previous crashed server.
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create the socket.
        let serverFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw ServerError.socketCreateFailed(errno)
        }

        // Set SO_REUSEADDR so we can rebind quickly after a crash.
        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Build the sockaddr_un and bind.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed-size C char array (104 bytes on Darwin).
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                _ = strlcpy(cptr, socketPath, 104)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(serverFd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFd)
            throw ServerError.bindFailed(errno)
        }

        // Start listening.
        guard Darwin.listen(serverFd, 128) == 0 else {
            Darwin.close(serverFd)
            throw ServerError.listenFailed(errno)
        }

        // Write PID file so clients can detect the running server.
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // Launch the accept loop as a background task.
        let capturedFd = serverFd
        acceptTask = Task {
            await self.acceptLoop(serverFd: capturedFd)
        }
    }

    /// Shut down the server: cancel tasks, remove socket/PID files, invoke `onShutdown`.
    public func shutdown() {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        acceptTask?.cancel()
        acceptTask = nil

        if let path = currentSocketPath {
            try? FileManager.default.removeItem(atPath: path)
            currentSocketPath = nil
        }
        if let path = currentPidPath {
            try? FileManager.default.removeItem(atPath: path)
            currentPidPath = nil
        }

        onShutdown()
    }

    // MARK: - Accept loop

    private func acceptLoop(serverFd: Int32) async {
        defer { Darwin.close(serverFd) }

        while !Task.isCancelled {
            // accept() is a blocking call; run it on a background thread so we
            // don't tie up the Swift concurrency cooperative thread pool.
            let clientFd = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                let thread = Thread {
                    let fd = Darwin.accept(serverFd, nil, nil)
                    continuation.resume(returning: fd)
                }
                thread.start()
            }

            guard clientFd >= 0 else {
                // accept() returned an error — socket was closed (shutdown).
                return
            }

            // Handle each connection concurrently without blocking the accept loop.
            Task {
                await self.handleConnection(clientFd: clientFd)
            }
        }
    }

    private func handleConnection(clientFd: Int32) async {
        defer { Darwin.close(clientFd) }

        // Read in chunks, accumulating until we can successfully parse the request.
        var buffer = Data()
        let chunkSize = 65536

        while true {
            let chunk = await readChunk(fd: clientFd, maxBytes: chunkSize)
            if let data = chunk {
                buffer.append(data)
            }

            // Attempt to parse what we have accumulated so far.
            if let request = try? HTTPParser.parseRequest(buffer) {
                let response = await self.handleRequest(request)
                let responseData = HTTPParser.serializeResponse(response)
                await writeAllData(fd: clientFd, data: responseData)
                return
            }

            // Hit EOF/error and still cannot parse — drop the connection silently.
            if chunk == nil {
                return
            }
        }
    }

    /// Read up to `maxBytes` bytes from `fd` on a background thread.
    /// Returns `nil` on EOF or error.
    private func readChunk(fd: Int32, maxBytes: Int) async -> Data? {
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

    /// Write all bytes of `data` to `fd`, looping until complete or error.
    private func writeAllData(fd: Int32, data: Data) async {
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

    // MARK: - Request routing

    /// Single public entry point for all HTTP requests.
    /// Resets the idle timer on every call and dispatches to the appropriate stub handler.
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        armIdleTimer()

        switch (request.method, request.path) {

        // Health
        case ("GET", "/health"):
            return handleHealth()

        // Screen size
        case ("GET", "/screen-size"):
            return handleScreenSize()

        // Screenshot
        case ("POST", "/screenshot"):
            return handleScreenshot()

        // Input: combined press
        case ("POST", "/input/key"):
            return handleInputKey(request)
        case ("POST", "/input/key-down"):
            return handleInputKeyDown(request)
        case ("POST", "/input/key-up"):
            return handleInputKeyUp(request)
        case ("POST", "/input/type"):
            return handleInputType(request)
        case ("POST", "/input/click"):
            return handleInputClick(request)
        case ("POST", "/input/mouse-down"):
            return handleInputMouseDown(request)
        case ("POST", "/input/mouse-up"):
            return handleInputMouseUp(request)
        case ("POST", "/input/move"):
            return handleInputMove(request)
        case ("POST", "/input/scroll"):
            return handleInputScroll(request)
        case ("POST", "/input/drag"):
            return handleInputDrag(request)

        // SSH
        case ("POST", "/ssh/exec"):
            return handleSSHExec(request)
        case ("POST", "/ssh/upload"):
            return handleSSHUpload(request)
        case ("POST", "/ssh/download"):
            return handleSSHDownload(request)

        // Recording
        case ("POST", "/record/start"):
            return handleRecordStart()
        case ("POST", "/record/stop"):
            return handleRecordStop()

        // Stop the server
        case ("POST", "/stop"):
            return handleStop()

        // Wrong method on a known path — 405
        case (_, "/health"),
             (_, "/screen-size"),
             (_, "/screenshot"),
             (_, "/input/key"),
             (_, "/input/key-down"),
             (_, "/input/key-up"),
             (_, "/input/type"),
             (_, "/input/click"),
             (_, "/input/mouse-down"),
             (_, "/input/mouse-up"),
             (_, "/input/move"),
             (_, "/input/scroll"),
             (_, "/input/drag"),
             (_, "/ssh/exec"),
             (_, "/ssh/upload"),
             (_, "/ssh/download"),
             (_, "/record/start"),
             (_, "/record/stop"),
             (_, "/stop"):
            return methodNotAllowed()

        // Unknown path — 404
        default:
            return notFound()
        }
    }

    // MARK: - Idle timer

    /// Cancel the current timer and start a fresh one.
    private func armIdleTimer() {
        idleTimerTask?.cancel()
        let timeout = idleTimeout
        idleTimerTask = Task {
            do {
                try await Task.sleep(for: timeout)
                self.shutdown()
            } catch {
                // Cancelled — a new request arrived; nothing to do.
            }
        }
    }

    // MARK: - Stub handlers

    private func handleHealth() -> HTTPResponse {
        json(body: #"{"status":"ok"}"#)
    }

    private func handleScreenSize() -> HTTPResponse {
        json(body: #"{"width":0,"height":0}"#)
    }

    private func handleScreenshot() -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputKey(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputKeyDown(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputKeyUp(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputType(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputClick(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputMouseDown(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputMouseUp(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputMove(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputScroll(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleInputDrag(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleSSHExec(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleSSHUpload(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleSSHDownload(_ request: HTTPRequest) -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleRecordStart() -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleRecordStop() -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    private func handleStop() -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

    // MARK: - Response helpers

    private func json(statusCode: Int = 200, body: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            contentType: "application/json",
            body: Data(body.utf8)
        )
    }

    private func notFound() -> HTTPResponse {
        json(statusCode: 404, body: #"{"error":"not found"}"#)
    }

    private func methodNotAllowed() -> HTTPResponse {
        json(statusCode: 405, body: #"{"error":"method not allowed"}"#)
    }
}
