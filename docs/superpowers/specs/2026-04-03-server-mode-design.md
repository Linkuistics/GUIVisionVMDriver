# Server Mode for GUIVisionVMDriver

## Problem

Every `guivision` CLI invocation creates a new VNC connection (TCP handshake, RFB negotiation, authentication, first framebuffer wait) and a new SSH process. When an LLM automation script chains dozens of commands sequentially, this per-command overhead is significant.

## Solution

A transparent connection-caching server that auto-starts on first CLI use, holds persistent VNC and SSH connections, and self-terminates after a short idle timeout.

Users see no CLI interface changes. The server is an invisible optimization.

## Architecture

### Server Process

The server is the `guivision` binary itself, invoked via a hidden subcommand:

```
guivision _server --connect-json '<json>' --idle-timeout 10
```

It is an `actor` that owns:
- A `VNCCapture` instance, connected at startup
- An `SSHClient` instance, created at startup (connects on first SSH request)
- An idle timer that resets on each request and triggers shutdown when it fires

### Transport

- **Unix domain socket** at `/tmp/guivision-<sha256-of-connection-spec>.sock`
- **HTTP/1.1** request/response protocol with JSON bodies (PNG for screenshot responses)
- PID file at `/tmp/guivision-<hash>.pid` for cleanup

Socket path is derived from a SHA-256 hash of the `ConnectionSpec` encoded as JSON with `.sortedKeys` to ensure deterministic output. Different connection targets get independent server instances.

### HTTP Server Implementation

Uses Foundation's `NWListener` (Network.framework) over Unix domain sockets. HTTP parsing is minimal and hand-rolled — we only need: method, path, `Content-Length` header, and body. No streaming, chunked encoding, or keep-alive.

Requests are serialized through the actor. VNC operations on a single connection should not be concurrent.

### Idle Timeout

Default: 10 seconds. On each request, the server cancels the current idle `Task` and starts a new one. When the timer fires, the server shuts down cleanly (close connections, remove socket/PID files, exit).

## API Surface

All endpoints are served over the Unix domain socket.

### Health

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/health` | — | `{"status":"ok"}` |

### Display

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/screen-size` | — | `{"width":1920,"height":1080}` |
| POST | `/screenshot` | `{"region":"x,y,w,h"}` (optional) | PNG bytes (`image/png`) |

### Keyboard Input

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/input/key` | `{"key":"a","modifiers":["cmd"]}` | `{"ok":true}` |
| POST | `/input/key-down` | `{"key":"shift"}` | `{"ok":true}` |
| POST | `/input/key-up` | `{"key":"shift"}` | `{"ok":true}` |
| POST | `/input/type` | `{"text":"hello"}` | `{"ok":true}` |

### Mouse Input

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/input/click` | `{"x":100,"y":200,"button":"left","count":1}` | `{"ok":true}` |
| POST | `/input/mouse-down` | `{"x":100,"y":200,"button":"left"}` | `{"ok":true}` |
| POST | `/input/mouse-up` | `{"x":100,"y":200,"button":"left"}` | `{"ok":true}` |
| POST | `/input/move` | `{"x":100,"y":200}` | `{"ok":true}` |
| POST | `/input/scroll` | `{"x":100,"y":200,"dx":0,"dy":-3}` | `{"ok":true}` |
| POST | `/input/drag` | `{"fromX":0,"fromY":0,"toX":100,"toY":100,"button":"left","steps":10}` | `{"ok":true}` |

### SSH

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/ssh/exec` | `{"command":"echo hi","timeout":30}` | `{"exitCode":0,"stdout":"hi","stderr":""}` |
| POST | `/ssh/upload` | `{"localPath":"/a","remotePath":"/b"}` | `{"ok":true}` |
| POST | `/ssh/download` | `{"remotePath":"/a","localPath":"/b"}` | `{"ok":true}` |

### Recording

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/record/start` | `{"output":"recording.mp4","fps":30,"duration":60,"region":"x,y,w,h"}` (region optional) | `{"ok":true}` |
| POST | `/record/stop` | — | `{"ok":true}` |

`duration` is required and capped at 300 seconds (5 minutes). The server runs the capture loop internally — it already holds the `VNCCapture` and can write frames directly to the `StreamingCapture` writer without serializing frame data over the socket. Only one recording can be active at a time; starting a second returns an error.

The recording auto-stops when the duration elapses. The client can also call `/record/stop` early. The idle timer is suspended while a recording is active but the duration cap guarantees the server cannot be pinned alive indefinitely by a crashed client.

### Server Control

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/stop` | — | `{"ok":true}` (then server exits) |

### Errors

All errors return HTTP 4xx or 5xx with body `{"error":"descriptive message"}`.

## Client-Side Transparent Proxying

### ServerClient

A new `ServerClient` type in the library provides:

```swift
let client = try await ServerClient.ensure(spec: spec)
let pngData = try await client.screenshot(region: nil)
try await client.pressKey("a", modifiers: ["cmd"])
let result = try await client.sshExec("echo hi")
```

### Auto-Start Sequence

1. Compute socket path from SHA-256 of the connection spec's canonical JSON
2. Try `GET /health` on the socket
3. If it responds, reuse the existing server
4. If not (socket missing or connection refused):
   a. Clean up stale socket/PID files
   b. Spawn `guivision _server --connect-json '...' --idle-timeout 10` as a background process
   c. Wait for `ready` on the child's stdout (server prints this after VNC connects and socket is bound)
   d. If startup fails, propagate the error (hard failure, no fallback)

### Command Transformation

Each command's `run()` changes from:

```swift
let spec = try connection.resolve()
let capture = VNCCapture(spec: spec.vnc)
try await capture.connect()
defer { Task { await capture.disconnect() } }
// ... use capture directly
```

To:

```swift
let spec = try connection.resolve()
let client = try await ServerClient.ensure(spec: spec)
// ... use client methods
```

### Record Command

`RecordCommand` calls `client.recordStart(output:fps:region:)` and `client.recordStop()`. The server runs the capture loop internally using its connected `VNCCapture` and `StreamingCapture`, writing frames directly without serialization overhead. The client blocks waiting for Ctrl+C or the duration to elapse, then calls stop.

## File Layout

### New Files

| File | Purpose |
|------|---------|
| `Sources/GUIVisionVMDriver/Server/GUIVisionServer.swift` | Actor: holds VNC + SSH connections, routes HTTP requests, manages idle timer |
| `Sources/GUIVisionVMDriver/Server/HTTPParser.swift` | Minimal HTTP/1.1 request/response parsing over `NWConnection` |
| `Sources/GUIVisionVMDriver/Server/ServerClient.swift` | Client: ensure server running, send HTTP requests, parse responses |
| `Sources/guivision/ServerCommand.swift` | Hidden `_server` subcommand: argument parsing, startup orchestration |

### Modified Files

| File | Change |
|------|--------|
| `Sources/guivision/GUIVisionCLI.swift` | Add `ServerCommand` to subcommands |
| `Sources/guivision/ScreenshotCommand.swift` | Use `ServerClient` instead of direct `VNCCapture` |
| `Sources/guivision/ScreenSizeCommand.swift` | Use `ServerClient` instead of direct `VNCCapture` |
| `Sources/guivision/InputCommand.swift` | Use `ServerClient` instead of direct `VNCCapture` |
| `Sources/guivision/SSHCommand.swift` | Use `ServerClient` instead of direct `SSHClient` |
| `Sources/guivision/RecordCommand.swift` | Use `ServerClient.screenshotData()` in capture loop |

### Unmodified

- `Package.swift` — Network.framework is available on macOS 14+ (already the minimum target)
- `ConnectionSpec`, `VNCCapture`, `VNCInput`, `SSHClient`, `StreamingCapture`, `FramebufferConverter` — used internally by the server, not changed
- All test files
