# Server Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a transparent connection-caching server that auto-starts on first CLI use, holds persistent VNC + SSH connections, and self-terminates after idle timeout — eliminating per-command reconnection overhead.

**Architecture:** The `guivision` binary gains a hidden `_server` subcommand that listens on a Unix domain socket (keyed by connection spec hash) and serves an HTTP/1.1 API. CLI commands transparently proxy through the server via a `ServerClient` that auto-starts the server if needed. The server uses Network.framework (`NWListener`) for socket I/O.

**Tech Stack:** Swift 6, Network.framework (NWListener/NWConnection), Foundation, CryptoKit (SHA-256), Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-03-server-mode-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `Sources/GUIVisionVMDriver/Server/HTTPParser.swift` | Minimal HTTP/1.1 request parsing and response serialization over `NWConnection` |
| `Sources/GUIVisionVMDriver/Server/GUIVisionServer.swift` | Actor that holds VNC + SSH connections, routes requests to handlers, manages idle timer and recording state |
| `Sources/GUIVisionVMDriver/Server/ServerClient.swift` | Client-side: compute socket path, health-check, auto-start server, send HTTP requests and parse responses |
| `Sources/guivision/ServerCommand.swift` | Hidden `_server` AsyncParsableCommand: accepts `--connect-json` and `--idle-timeout`, wires up and runs the server |
| `Tests/GUIVisionVMDriverTests/Server/HTTPParserTests.swift` | Unit tests for HTTP parsing |
| `Tests/GUIVisionVMDriverTests/Server/ServerClientTests.swift` | Unit tests for socket path computation and request/response building |
| `Tests/GUIVisionVMDriverTests/Server/GUIVisionServerTests.swift` | Unit tests for request routing and idle timer behavior |

### Modified Files

| File | Change |
|------|--------|
| `Sources/guivision/GUIVisionCLI.swift` | Add `ServerCommand` to subcommands list |
| `Sources/guivision/ScreenshotCommand.swift` | Replace direct `VNCCapture` usage with `ServerClient` |
| `Sources/guivision/ScreenSizeCommand.swift` | Replace direct `VNCCapture` usage with `ServerClient` |
| `Sources/guivision/InputCommand.swift` | Replace direct `VNCCapture` usage with `ServerClient` in all 10 subcommands |
| `Sources/guivision/SSHCommand.swift` | Replace direct `SSHClient` usage with `ServerClient` in all 3 subcommands |
| `Sources/guivision/RecordCommand.swift` | Replace local capture loop with `ServerClient.recordStart` / `recordStop` |

---

## Task 1: Minimal HTTP Parser

**Files:**
- Create: `Sources/GUIVisionVMDriver/Server/HTTPParser.swift`
- Create: `Tests/GUIVisionVMDriverTests/Server/HTTPParserTests.swift`

This is the foundation everything else builds on. It needs to parse incoming HTTP/1.1 requests from raw bytes (method, path, Content-Length, body) and serialize HTTP responses (status code, content-type, body). No chunked encoding, no keep-alive, no transfer-encoding — just the bare minimum for request/response over a Unix socket.

- [ ] **Step 1:** Define the request and response types. `HTTPRequest` holds method, path, and optional body bytes. `HTTPResponse` holds status code, content type, and body bytes. Both are simple structs.

- [ ] **Step 2:** Write tests for request parsing — cover: GET with no body, POST with JSON body, missing Content-Length on POST (should default to no body), malformed request line (should error). Use raw byte strings as input.

- [ ] **Step 3:** Run tests, verify they fail.

    ```
    swift test --filter HTTPParserTests
    ```

- [ ] **Step 4:** Implement the request parser. Read bytes until `\r\n\r\n` to find the header block. Parse the first line for method and path. Scan headers for `Content-Length`. If present, read that many body bytes.

- [ ] **Step 5:** Write tests for response serialization — cover: 200 with JSON body, 200 with PNG body (image/png content type), 400 with error JSON, 404 with error JSON.

- [ ] **Step 6:** Implement response serialization. Format as `HTTP/1.1 {status} {reason}\r\nContent-Type: {type}\r\nContent-Length: {len}\r\n\r\n{body}`.

- [ ] **Step 7:** Run all HTTPParser tests, verify they pass.

    ```
    swift test --filter HTTPParserTests
    ```

- [ ] **Step 8:** Commit.

---

## Task 2: Socket Path Computation

**Files:**
- Create: `Sources/GUIVisionVMDriver/Server/ServerClient.swift` (initial scaffold — socket path logic only)
- Create: `Tests/GUIVisionVMDriverTests/Server/ServerClientTests.swift`

The socket path must be deterministic for a given `ConnectionSpec` so that independent CLI invocations find the same server. This task implements just the hashing function.

- [ ] **Step 1:** Write tests for socket path computation — cover: same spec produces same path, different specs produce different paths, path is under `/tmp/guivision-<hex>.sock`, the PID file path follows the same pattern with `.pid` extension.

- [ ] **Step 2:** Run tests, verify they fail.

    ```
    swift test --filter ServerClientTests
    ```

- [ ] **Step 3:** Implement the socket path function. JSON-encode the `ConnectionSpec` with `.sortedKeys`, SHA-256 hash it using CryptoKit, take the hex prefix (first 16 chars is sufficient), return `/tmp/guivision-{hex}.sock`. Add a matching function for the PID path.

- [ ] **Step 4:** Run tests, verify they pass.

    ```
    swift test --filter ServerClientTests
    ```

- [ ] **Step 5:** Commit.

---

## Task 3: GUIVisionServer Actor — Request Routing and Idle Timer

**Files:**
- Create: `Sources/GUIVisionVMDriver/Server/GUIVisionServer.swift`
- Create: `Tests/GUIVisionVMDriverTests/Server/GUIVisionServerTests.swift`

The server actor is the core. This task focuses on the request routing logic and idle timer — not the actual VNC/SSH operations yet (those are wired in Task 5). For now, the handler methods can be stubs that return success responses.

- [ ] **Step 1:** Write tests for request routing — given an `HTTPRequest` with various method+path combinations, verify the server dispatches to the correct handler and returns appropriate response types. Cover: `GET /health`, `GET /screen-size`, `POST /screenshot`, `POST /input/key`, `POST /input/type`, `POST /input/click`, `POST /ssh/exec`, `POST /record/start`, `POST /record/stop`, `POST /stop`, unknown path returns 404, wrong method returns 405.

- [ ] **Step 2:** Run tests, verify they fail.

    ```
    swift test --filter GUIVisionServerTests
    ```

- [ ] **Step 3:** Implement the server actor with a `handleRequest(_ request: HTTPRequest) -> HTTPResponse` method that switches on method+path and dispatches to stub handler methods. Include the idle timer: a `Task` that sleeps for the timeout duration, cancelled and restarted by `resetIdleTimer()` called at the top of `handleRequest`. The timer calls a shutdown closure when it fires.

- [ ] **Step 4:** Write a test for idle timer behavior — verify that a server with a very short timeout (e.g., 0.1s) calls its shutdown closure after the timeout elapses with no requests.

- [ ] **Step 5:** Run all server tests, verify they pass.

    ```
    swift test --filter GUIVisionServerTests
    ```

- [ ] **Step 6:** Commit.

---

## Task 4: Server Listener — NWListener over Unix Socket

**Files:**
- Modify: `Sources/GUIVisionVMDriver/Server/GUIVisionServer.swift`

This task adds the networking layer: the server binds an `NWListener` to the Unix domain socket, accepts connections, reads HTTP requests using `HTTPParser`, dispatches to the actor's `handleRequest`, and writes HTTP responses back.

- [ ] **Step 1:** Add a `start(socketPath:)` method to the server that creates an `NWListener` on the Unix domain socket path, sets up the `newConnectionHandler` to read requests and write responses, and writes the PID file.

- [ ] **Step 2:** Add a `shutdown()` method that stops the listener, removes the socket file and PID file, and disconnects VNC/SSH.

- [ ] **Step 3:** Wire the idle timer's expiry to call `shutdown()`.

- [ ] **Step 4:** Verify the server compiles.

    ```
    swift build
    ```

- [ ] **Step 5:** Commit.

---

## Task 5: Wire Server Handlers to VNC and SSH

**Files:**
- Modify: `Sources/GUIVisionVMDriver/Server/GUIVisionServer.swift`

Replace the stub handlers from Task 3 with real implementations that use the server's `VNCCapture` and `SSHClient` instances.

- [ ] **Step 1:** Implement the server's init to accept a `ConnectionSpec`, create a `VNCCapture` from the VNC spec, and create an `SSHClient` from the SSH spec (if present). Add a `connect()` method that calls `VNCCapture.connect()`.

- [ ] **Step 2:** Implement `/health` — return `{"status":"ok"}`.

- [ ] **Step 3:** Implement `/screen-size` — call `capture.screenSize()`, return JSON with width and height.

- [ ] **Step 4:** Implement `/screenshot` — parse optional region from request body, call `capture.screenshot(region:)`, return PNG data with `image/png` content type.

- [ ] **Step 5:** Implement all `/input/*` handlers — parse JSON body, call the corresponding `VNCInput` static method via `capture.withConnection`. Each handler: `/input/key` calls `pressKey`, `/input/key-down` calls `keyDown`, `/input/key-up` calls `keyUp`, `/input/type` calls `typeText`, `/input/click` calls `click`, `/input/mouse-down` calls `mouseDown`, `/input/mouse-up` calls `mouseUp`, `/input/move` calls `mouseMove`, `/input/scroll` calls `scroll`, `/input/drag` calls `drag`. Use the connection spec's platform for key mapping.

- [ ] **Step 6:** Implement `/ssh/exec` — parse command and optional timeout from body, call `sshClient.exec()`, return JSON with exitCode, stdout, stderr. Return 400 if no SSH spec was configured.

- [ ] **Step 7:** Implement `/ssh/upload` and `/ssh/download` — parse paths from body, call the corresponding `SSHClient` method.

- [ ] **Step 8:** Implement `/record/start` — parse output, fps, duration (required, max 300), and optional region from body. Verify no recording is already active. Create a `StreamingCapture`, start it, launch a detached `Task` that captures frames in a loop for the specified duration, then auto-stops. Suspend the idle timer while recording.

- [ ] **Step 9:** Implement `/record/stop` — stop the active recording task and `StreamingCapture`, resume the idle timer. No-op if no recording is active.

- [ ] **Step 10:** Implement `/stop` — return `{"ok":true}`, then call `shutdown()`.

- [ ] **Step 11:** Verify the server compiles.

    ```
    swift build
    ```

- [ ] **Step 12:** Commit.

---

## Task 6: ServerClient — HTTP Client over Unix Socket

**Files:**
- Modify: `Sources/GUIVisionVMDriver/Server/ServerClient.swift`

Extend the `ServerClient` (which already has socket path computation from Task 2) with the ability to send HTTP requests over the Unix socket and parse responses.

- [ ] **Step 1:** Add tests for request sending and response parsing — construct an `HTTPRequest`, serialize it, verify the bytes match expected HTTP format. Parse a raw HTTP response, verify fields are extracted correctly.

- [ ] **Step 2:** Run tests, verify they fail.

    ```
    swift test --filter ServerClientTests
    ```

- [ ] **Step 3:** Implement the Unix socket client using `NWConnection` with `NWEndpoint.unix(path:)`. Provide a `send(_ request: HTTPRequest) async throws -> HTTPResponse` method that connects, writes the request bytes, reads the response bytes, parses them, and disconnects.

- [ ] **Step 4:** Run tests, verify they pass.

    ```
    swift test --filter ServerClientTests
    ```

- [ ] **Step 5:** Commit.

---

## Task 7: ServerClient — Auto-Start and Public API

**Files:**
- Modify: `Sources/GUIVisionVMDriver/Server/ServerClient.swift`

Add the `ensure(spec:)` factory method and the high-level API methods that CLI commands will use.

- [ ] **Step 1:** Implement `ensure(spec:idleTimeout:)` — compute socket path, try `GET /health`, if it responds return a client. Otherwise: clean up stale socket/PID files, resolve the path to the `guivision` binary (using `CommandLine.arguments[0]` or `Bundle.main.executablePath`), spawn `guivision _server --connect-json '<spec>' --idle-timeout <N>` as a background `Process`, read stdout until `ready` line appears (with a timeout), then health-check. On any failure, throw a descriptive error.

- [ ] **Step 2:** Add high-level API methods that wrap the HTTP calls. Each method constructs the appropriate `HTTPRequest`, calls `send()`, and parses the response. Methods: `screenshot(region:) -> Data`, `screenSize() -> CGSize`, `pressKey(_:modifiers:)`, `keyDown(_:)`, `keyUp(_:)`, `typeText(_:)`, `click(x:y:button:count:)`, `mouseDown(x:y:button:)`, `mouseUp(x:y:button:)`, `mouseMove(x:y:)`, `scroll(x:y:dx:dy:)`, `drag(fromX:fromY:toX:toY:button:steps:)`, `sshExec(_:timeout:) -> SSHResult`, `sshUpload(localPath:remotePath:)`, `sshDownload(remotePath:localPath:)`, `recordStart(output:fps:duration:region:)`, `recordStop()`, `stop()`.

- [ ] **Step 3:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 4:** Commit.

---

## Task 8: ServerCommand — Hidden `_server` Subcommand

**Files:**
- Create: `Sources/guivision/ServerCommand.swift`
- Modify: `Sources/guivision/GUIVisionCLI.swift`

This is the entry point that the auto-start mechanism spawns.

- [ ] **Step 1:** Create `ServerCommand` as an `AsyncParsableCommand` with command name `_server`. It takes `--connect-json` (required String) and `--idle-timeout` (Int, default 10). Its `run()` decodes the JSON into a `ConnectionSpec`, creates a `GUIVisionServer`, calls `connect()` then `start(socketPath:)`, prints `ready` to stdout, and then awaits shutdown (e.g., via an async signal or the server's shutdown completion).

- [ ] **Step 2:** Add `ServerCommand.self` to the subcommands array in `GUIVisionCLI.swift`. It should not appear in help text — set `shouldDisplay: false` in the command configuration.

- [ ] **Step 3:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 4:** Commit.

---

## Task 9: Convert ScreenshotCommand and ScreenSizeCommand

**Files:**
- Modify: `Sources/guivision/ScreenshotCommand.swift`
- Modify: `Sources/guivision/ScreenSizeCommand.swift`

Start with these two commands as they're the simplest — one returns PNG data, one returns dimensions.

- [ ] **Step 1:** Modify `ScreenshotCommand.run()` — replace the `VNCCapture` connect/screenshot/disconnect sequence with `ServerClient.ensure(spec:)` then `client.screenshot(region:)`. Keep the file-writing and output message unchanged.

- [ ] **Step 2:** Modify `ScreenSizeCommand.run()` — replace the `VNCCapture` connect/screenSize/disconnect sequence with `ServerClient.ensure(spec:)` then `client.screenSize()`.

- [ ] **Step 3:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 4:** Commit.

---

## Task 10: Convert InputCommand Subcommands

**Files:**
- Modify: `Sources/guivision/InputCommand.swift`

All 10 input subcommands follow the same pattern. Convert each one.

- [ ] **Step 1:** Convert `KeyPressCommand` — replace `VNCCapture` connect/withConnection/disconnect with `ServerClient.ensure` then `client.pressKey(_:modifiers:)`.

- [ ] **Step 2:** Convert `KeyDownCommand` and `KeyUpCommand` similarly.

- [ ] **Step 3:** Convert `TypeCommand`.

- [ ] **Step 4:** Convert `ClickCommand`.

- [ ] **Step 5:** Convert `MouseDownCommand` and `MouseUpCommand`.

- [ ] **Step 6:** Convert `MoveCommand`.

- [ ] **Step 7:** Convert `ScrollCommand`.

- [ ] **Step 8:** Convert `DragCommand`.

- [ ] **Step 9:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 10:** Commit.

---

## Task 11: Convert SSHCommand Subcommands

**Files:**
- Modify: `Sources/guivision/SSHCommand.swift`

- [ ] **Step 1:** Convert `ExecCommand` — replace direct `SSHClient` usage with `ServerClient.ensure` then `client.sshExec()`. Preserve the stdout/stderr/exit-code output behavior.

- [ ] **Step 2:** Convert `UploadCommand` and `DownloadCommand` similarly.

- [ ] **Step 3:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 4:** Commit.

---

## Task 12: Convert RecordCommand

**Files:**
- Modify: `Sources/guivision/RecordCommand.swift`

- [ ] **Step 1:** Convert `RecordCommand.run()` — replace the local VNCCapture + StreamingCapture loop with `ServerClient.ensure` then `client.recordStart(output:fps:duration:region:)`. If `--duration 0` was specified, use the 300s cap. After calling start, sleep for the duration (or handle Ctrl+C with a signal handler), then call `client.recordStop()`.

- [ ] **Step 2:** Verify it compiles.

    ```
    swift build
    ```

- [ ] **Step 3:** Commit.

---

## Task 13: Integration Smoke Test

**Files:**
- No new files — uses existing VM test infrastructure

This is a manual verification step using the existing tart VM scripts.

- [ ] **Step 1:** Start a test VM.

    ```
    source scripts/vm-start.sh
    ```

- [ ] **Step 2:** Run a sequence of commands and verify the server auto-starts and reuses the connection:

    ```
    guivision screen-size --vnc "$GUIVISION_TEST_VNC"
    guivision screenshot --vnc "$GUIVISION_TEST_VNC" -o /tmp/test.png
    guivision input key --vnc "$GUIVISION_TEST_VNC" --platform macos a
    guivision ssh exec --ssh "$GUIVISION_TEST_SSH" "echo hello"
    ```

    The first command should take longer (server startup + VNC connect). Subsequent commands should be noticeably faster.

- [ ] **Step 3:** Verify the server socket exists under `/tmp/guivision-*.sock`.

- [ ] **Step 4:** Wait for the idle timeout (10s), then verify the socket is gone (server self-terminated).

- [ ] **Step 5:** Test recording:

    ```
    guivision record --vnc "$GUIVISION_TEST_VNC" -o /tmp/test.mp4 --duration 5
    ```

- [ ] **Step 6:** Stop the VM.

    ```
    source scripts/vm-stop.sh
    ```

- [ ] **Step 7:** Commit any fixes discovered during smoke testing.

---

## Task 14: Update Documentation

**Files:**
- Modify: `LLM_INSTRUCTIONS.md`

- [ ] **Step 1:** Add a section to LLM_INSTRUCTIONS.md explaining server mode behavior: that CLI commands transparently use a connection-caching server, that the server auto-starts and auto-stops, and that no user action is required.

- [ ] **Step 2:** Update the "Tips" section — remove or update the note that says "each CLI invocation connects/disconnects independently" since that's no longer true.

- [ ] **Step 3:** Commit.
