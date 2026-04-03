import CoreGraphics
import Darwin
import Foundation
@preconcurrency import RoyalVNCKit

// MARK: - Server errors

public enum ServerError: Error, Sendable {
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

// MARK: - Shared request types

private struct SingleKeyRequest: Decodable { let key: String }

private struct MouseRequest: Decodable {
    let x: UInt16
    let y: UInt16
    let button: String?
}

/// The core server actor that routes HTTP requests and manages an idle timer.
///
/// The idle timer starts immediately on init. Each `handleRequest(_:)` call
/// cancels the current timer and starts a fresh one. When the timer fires
/// without a new request, the server shuts down.
///
/// Call `start(socketPath:pidPath:)` after init to bind the Unix socket and
/// begin accepting connections.
public actor GUIVisionServer {

    // MARK: - Properties

    private let spec: ConnectionSpec
    private let idleTimeout: Duration
    public let onShutdown: @Sendable () -> Void

    /// VNC capture actor for screenshots and input delivery.
    private let capture: VNCCapture

    /// SSH client — nil if no SSH spec was provided.
    private let sshClient: SSHClient?

    /// The currently pending idle timer task. Cancelled and replaced on every request.
    private var idleTimerTask: Task<Void, Never>?

    /// The background accept-loop task. Cancelled by `shutdown()`.
    private var acceptTask: Task<Void, Never>?

    /// Paths stored so `shutdown()` can remove them.
    private var currentSocketPath: String?
    private var currentPidPath: String?

    /// Active recording state.
    private var recordingCapture: StreamingCapture?
    private var recordingTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        spec: ConnectionSpec,
        idleTimeout: Duration,
        onShutdown: @escaping @Sendable () -> Void
    ) {
        self.spec = spec
        self.idleTimeout = idleTimeout
        self.onShutdown = onShutdown
        self.capture = VNCCapture(spec: spec.vnc)
        self.sshClient = spec.ssh.map { SSHClient(spec: $0) }
        // Swift 6 strict concurrency: actor-isolated stored properties cannot be
        // assigned from within a Task closure in a nonisolated initializer.
        // We work around this by calling the onShutdown closure directly
        // (a captured value, not actor state).
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

    // MARK: - Connect

    /// Connect the VNC session. Call this after `start(socketPath:pidPath:)`.
    public func connect() async throws {
        try await capture.connect()
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

        recordingTask?.cancel()
        recordingTask = nil

        // Stop the StreamingCapture asynchronously since shutdown() is not async.
        if let sc = recordingCapture {
            recordingCapture = nil
            Task { try? await sc.stop() }
        }

        if let path = currentSocketPath {
            try? FileManager.default.removeItem(atPath: path)
            currentSocketPath = nil
        }
        if let path = currentPidPath {
            try? FileManager.default.removeItem(atPath: path)
            currentPidPath = nil
        }

        // VNCCapture is an actor — disconnect asynchronously.
        let captureRef = capture
        Task { await captureRef.disconnect() }
        sshClient?.disconnect()
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
    /// Resets the idle timer on every call (unless recording) and dispatches to the handler.
    public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // Don't re-arm the idle timer while a recording is active.
        if recordingTask == nil {
            armIdleTimer()
        }

        switch (request.method, request.path) {

        // Health
        case ("GET", "/health"):
            return handleHealth()

        // Screen size
        case ("GET", "/screen-size"):
            return await handleScreenSize()

        // Screenshot
        case ("POST", "/screenshot"):
            return await handleScreenshot(request)

        // Input: combined press
        case ("POST", "/input/key"):
            return await handleInputKey(request)
        case ("POST", "/input/key-down"):
            return await handleInputKeyDown(request)
        case ("POST", "/input/key-up"):
            return await handleInputKeyUp(request)
        case ("POST", "/input/type"):
            return await handleInputType(request)
        case ("POST", "/input/click"):
            return await handleInputClick(request)
        case ("POST", "/input/mouse-down"):
            return await handleInputMouseDown(request)
        case ("POST", "/input/mouse-up"):
            return await handleInputMouseUp(request)
        case ("POST", "/input/move"):
            return await handleInputMove(request)
        case ("POST", "/input/scroll"):
            return await handleInputScroll(request)
        case ("POST", "/input/drag"):
            return await handleInputDrag(request)

        // SSH
        case ("POST", "/ssh/exec"):
            return handleSSHExec(request)
        case ("POST", "/ssh/upload"):
            return handleSSHUpload(request)
        case ("POST", "/ssh/download"):
            return handleSSHDownload(request)

        // Recording
        case ("POST", "/record/start"):
            return await handleRecordStart(request)
        case ("POST", "/record/stop"):
            return await handleRecordStop()

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

    // MARK: - Handlers

    private func handleHealth() -> HTTPResponse {
        json(body: #"{"status":"ok"}"#)
    }

    private func handleScreenSize() async -> HTTPResponse {
        guard let size = await capture.screenSize() else {
            return json(statusCode: 503, body: #"{"error":"screen size unavailable — VNC not connected"}"#)
        }
        let w = Int(size.width)
        let h = Int(size.height)
        return json(body: "{\"width\":\(w),\"height\":\(h)}")
    }

    private func handleScreenshot(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let region = try parseRegion(from: request)
            let pngData = try await capture.screenshot(region: region)
            return HTTPResponse(statusCode: 200, contentType: "image/png", body: pngData)
        } catch {
            return serverError(error)
        }
    }

    private func handleInputKey(_ request: HTTPRequest) async -> HTTPResponse {
        struct KeyRequest: Decodable {
            let key: String
            let modifiers: [String]?
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(KeyRequest.self, from: body)
            let platform = spec.platform
            let key = req.key
            let modifiers = req.modifiers ?? []
            try await capture.withConnection { conn in
                try VNCInput.pressKey(key, modifiers: modifiers, platform: platform, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputKeyDown(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(SingleKeyRequest.self, from: body)
            let platform = spec.platform
            let key = req.key
            try await capture.withConnection { conn in
                try VNCInput.keyDown(key, platform: platform, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputKeyUp(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(SingleKeyRequest.self, from: body)
            let platform = spec.platform
            let key = req.key
            try await capture.withConnection { conn in
                try VNCInput.keyUp(key, platform: platform, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputType(_ request: HTTPRequest) async -> HTTPResponse {
        struct TypeRequest: Decodable { let text: String }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(TypeRequest.self, from: body)
            let text = req.text
            try await capture.withConnection { conn in
                VNCInput.typeText(text, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputClick(_ request: HTTPRequest) async -> HTTPResponse {
        struct ClickRequest: Decodable {
            let x: UInt16
            let y: UInt16
            let button: String?
            let count: Int?
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(ClickRequest.self, from: body)
            let x = req.x; let y = req.y
            let button = req.button ?? "left"
            let count = req.count ?? 1
            try await capture.withConnection { conn in
                try VNCInput.click(x: x, y: y, button: button, count: count, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputMouseDown(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(MouseRequest.self, from: body)
            let x = req.x; let y = req.y
            let button = req.button ?? "left"
            try await capture.withConnection { conn in
                try VNCInput.mouseDown(x: x, y: y, button: button, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputMouseUp(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(MouseRequest.self, from: body)
            let x = req.x; let y = req.y
            let button = req.button ?? "left"
            try await capture.withConnection { conn in
                try VNCInput.mouseUp(x: x, y: y, button: button, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputMove(_ request: HTTPRequest) async -> HTTPResponse {
        struct MoveRequest: Decodable { let x: UInt16; let y: UInt16 }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(MoveRequest.self, from: body)
            let x = req.x; let y = req.y
            try await capture.withConnection { conn in
                VNCInput.mouseMove(x: x, y: y, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputScroll(_ request: HTTPRequest) async -> HTTPResponse {
        struct ScrollRequest: Decodable {
            let x: UInt16
            let y: UInt16
            let dx: Int
            let dy: Int
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(ScrollRequest.self, from: body)
            let x = req.x; let y = req.y
            let dx = req.dx; let dy = req.dy
            try await capture.withConnection { conn in
                VNCInput.scroll(x: x, y: y, deltaX: dx, deltaY: dy, connection: conn)
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleInputDrag(_ request: HTTPRequest) async -> HTTPResponse {
        struct DragRequest: Decodable {
            let fromX: UInt16
            let fromY: UInt16
            let toX: UInt16
            let toY: UInt16
            let button: String?
            let steps: Int?
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(DragRequest.self, from: body)
            let fromX = req.fromX; let fromY = req.fromY
            let toX = req.toX; let toY = req.toY
            let button = req.button ?? "left"
            let steps = req.steps ?? 10
            try await capture.withConnection { conn in
                try VNCInput.drag(
                    fromX: fromX, fromY: fromY,
                    toX: toX, toY: toY,
                    button: button, steps: steps,
                    connection: conn
                )
            }
            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleSSHExec(_ request: HTTPRequest) -> HTTPResponse {
        struct ExecRequest: Decodable {
            let command: String
            let timeout: Double?
        }
        guard let ssh = sshClient else {
            return badRequest("no SSH spec configured")
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(ExecRequest.self, from: body)
            let result = try ssh.exec(req.command, timeout: req.timeout ?? 30)
            return json(body: "{\"exitCode\":\(result.exitCode),\"stdout\":\(escapeJSON(result.stdout)),\"stderr\":\(escapeJSON(result.stderr))}")
        } catch {
            return serverError(error)
        }
    }

    private func handleSSHUpload(_ request: HTTPRequest) -> HTTPResponse {
        struct UploadRequest: Decodable {
            let localPath: String
            let remotePath: String
            let timeout: Double?
        }
        guard let ssh = sshClient else {
            return badRequest("no SSH spec configured")
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(UploadRequest.self, from: body)
            let result = try ssh.upload(localPath: req.localPath, remotePath: req.remotePath, timeout: req.timeout ?? 60)
            return json(body: "{\"exitCode\":\(result.exitCode),\"stdout\":\(escapeJSON(result.stdout)),\"stderr\":\(escapeJSON(result.stderr))}")
        } catch {
            return serverError(error)
        }
    }

    private func handleSSHDownload(_ request: HTTPRequest) -> HTTPResponse {
        struct DownloadRequest: Decodable {
            let remotePath: String
            let localPath: String
            let timeout: Double?
        }
        guard let ssh = sshClient else {
            return badRequest("no SSH spec configured")
        }
        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(DownloadRequest.self, from: body)
            let result = try ssh.download(remotePath: req.remotePath, localPath: req.localPath, timeout: req.timeout ?? 60)
            return json(body: "{\"exitCode\":\(result.exitCode),\"stdout\":\(escapeJSON(result.stdout)),\"stderr\":\(escapeJSON(result.stderr))}")
        } catch {
            return serverError(error)
        }
    }

    private func handleRecordStart(_ request: HTTPRequest) async -> HTTPResponse {
        struct RecordRequest: Decodable {
            let output: String
            let fps: Int?
            let duration: Int
            let region: String?
        }

        if recordingTask != nil {
            return badRequest("recording already active")
        }

        do {
            guard let body = request.body else { return badRequest("missing request body") }
            let req = try JSONDecoder().decode(RecordRequest.self, from: body)

            let cappedDuration = min(req.duration, 300)
            guard cappedDuration > 0 else {
                return badRequest("duration must be > 0")
            }

            let region = try parseRegionFromString(req.region)

            // Determine video dimensions from region or full screen size.
            let (width, height): (Int, Int)
            if let r = region {
                width = Int(r.width)
                height = Int(r.height)
            } else if let size = await capture.screenSize() {
                width = Int(size.width)
                height = Int(size.height)
            } else {
                return json(statusCode: 503, body: #"{"error":"cannot determine screen size — VNC not connected"}"#)
            }

            let fps = req.fps ?? 30
            let sc = StreamingCapture()
            let config = StreamingCaptureConfig(width: width, height: height, fps: fps)
            try await sc.start(outputPath: req.output, config: config)
            self.recordingCapture = sc

            let taskFPS = fps
            let taskDuration = cappedDuration
            let captureSelf = self
            let captureSC = sc

            let task = Task.detached {
                let interval = Duration.nanoseconds(1_000_000_000 / max(taskFPS, 1))
                let deadline = ContinuousClock.now + .seconds(taskDuration)
                while !Task.isCancelled && ContinuousClock.now < deadline {
                    do {
                        let image = try await captureSelf.captureImage(region: region)
                        try await captureSC.appendFrame(image)
                    } catch {
                        // Frame capture failures are non-fatal — skip frame.
                    }
                    try? await Task.sleep(for: interval)
                }
                // Auto-stop when duration expires.
                await captureSelf.finishRecording()
            }
            self.recordingTask = task

            return ok()
        } catch {
            return serverError(error)
        }
    }

    private func handleRecordStop() async -> HTTPResponse {
        await finishRecording()
        return ok()
    }

    /// Cancel recording task, stop StreamingCapture, re-arm idle timer.
    private func finishRecording() async {
        recordingTask?.cancel()
        recordingTask = nil

        if let sc = recordingCapture {
            recordingCapture = nil
            try? await sc.stop()
        }

        // Resume idle timer after recording ends.
        armIdleTimer()
    }

    /// Expose captureImage to the detached recording task via actor isolation.
    fileprivate func captureImage(region: CGRect?) async throws -> CGImage {
        try await capture.captureImage(region: region)
    }

    private func handleStop() -> HTTPResponse {
        // Schedule shutdown after we return the response.
        Task {
            self.shutdown()
        }
        return json(body: #"{"ok":true}"#)
    }

    // MARK: - Body parsing helpers

    /// Parse an optional `region` field from JSON request body (format: `{"region":"x,y,w,h"}`).
    private func parseRegion(from request: HTTPRequest) throws -> CGRect? {
        struct RegionRequest: Decodable { let region: String? }
        guard let body = request.body, !body.isEmpty else { return nil }
        let req = try JSONDecoder().decode(RegionRequest.self, from: body)
        return try parseRegionFromString(req.region)
    }

    /// Parse a `"x,y,w,h"` string into a CGRect, or return nil if input is nil.
    private func parseRegionFromString(_ regionString: String?) throws -> CGRect? {
        guard let regionString else { return nil }
        let parts = regionString.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4 else {
            throw RegionParseError.invalid(regionString)
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - Response helpers

    private func ok() -> HTTPResponse {
        json(body: #"{"ok":true}"#)
    }

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

    private func badRequest(_ message: String) -> HTTPResponse {
        json(statusCode: 400, body: "{\"error\":\(escapeJSON(message))}")
    }

    private func serverError(_ error: Error) -> HTTPResponse {
        json(statusCode: 500, body: "{\"error\":\(escapeJSON(error.localizedDescription))}")
    }

    /// Produce a JSON-safe quoted string.
    private func escapeJSON(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.utf16.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: - Region parse error

private enum RegionParseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s):
            "Invalid region '\(s)'. Expected format: x,y,w,h"
        }
    }
}
