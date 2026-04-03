import Foundation

/// The core server actor that routes HTTP requests and manages an idle timer.
///
/// The idle timer starts immediately on init. Each `handleRequest(_:)` call
/// cancels the current timer and starts a fresh one. When the timer fires
/// without a new request, `onShutdown` is called.
///
/// Handler methods are stubs in this task; real VNC/SSH integration comes in Task 5.
public actor GUIVisionServer {

    // MARK: - Properties

    private let spec: ConnectionSpec
    private let idleTimeout: Duration
    public let onShutdown: @Sendable () -> Void

    /// The currently pending idle timer task. Cancelled and replaced on every request.
    private var idleTimerTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        spec: ConnectionSpec,
        idleTimeout: Duration,
        onShutdown: @escaping @Sendable () -> Void
    ) {
        self.spec = spec
        self.idleTimeout = idleTimeout
        self.onShutdown = onShutdown
        // Swift actors: a Task created in init runs isolated to `self`'s
        // executor. We directly assign idleTimerTask here so the very first
        // timer fires even if handleRequest is never called.
        let timeout = idleTimeout
        let shutdown = onShutdown
        idleTimerTask = Task {
            do {
                try await Task.sleep(for: timeout)
                shutdown()
            } catch {
                // Cancelled by a new request — nothing to do.
            }
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
        let shutdown = onShutdown
        idleTimerTask = Task {
            do {
                try await Task.sleep(for: timeout)
                shutdown()
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
