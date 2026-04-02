# GUIVisionVMDriver

A Swift library and CLI for interacting with machines via VNC and SSH. Designed for test automation, screenshot capture, video recording, and GUI-driven workflows.

## What It Does

**VNC capture and input:**
- Connect to any VNC server, capture screenshots (full or cropped), record video
- Query display dimensions
- Send keyboard events with platform-aware modifier mapping (Cmd/Alt/Ctrl work correctly on macOS, Windows, and Linux VMs)
- Individual key-down/key-up and mouse-down/mouse-up for fine-grained control
- Send mouse events: click, double-click, right-click, drag, scroll
- Type text with automatic handling of uppercase and shifted symbols
- Track cursor shape and position

**SSH command execution and file transfer:**
- Execute commands over SSH with stdout/stderr/exit code capture
- Upload and download files via SCP
- Persistent multiplexed connections via OpenSSH ControlMaster

**Streaming video capture:**
- Record VNC framebuffer to MP4 using AVAssetWriter
- Configurable resolution, frame rate, and codec (H.264/HEVC)

## CLI

```bash
# Display info
guivision screen-size --vnc localhost:5901                              # prints "1920x1080"

# Screenshot
guivision screenshot --vnc localhost:5901 -o screen.png
guivision screenshot --vnc localhost:5901 --region 0,0,800,600 -o cropped.png

# Keyboard — press and release
guivision input key --vnc localhost:5901 return
guivision input key --vnc localhost:5901 a --modifiers cmd
guivision input key --vnc localhost:5901 z --modifiers cmd,shift

# Keyboard — individual down/up
guivision input key-down --vnc localhost:5901 shift
guivision input key-up --vnc localhost:5901 shift

# Text entry
guivision input type --vnc localhost:5901 "Hello World!"

# Mouse — click
guivision input click --vnc localhost:5901 500 400
guivision input click --vnc localhost:5901 500 400 --button right
guivision input click --vnc localhost:5901 500 400 --count 2

# Mouse — individual down/up
guivision input mouse-down --vnc localhost:5901 100 200
guivision input mouse-down --vnc localhost:5901 100 200 --button right
guivision input mouse-up --vnc localhost:5901 100 200

# Mouse — move, scroll, drag
guivision input move --vnc localhost:5901 100 200
guivision input scroll --vnc localhost:5901 500 400 --dy -3
guivision input drag --vnc localhost:5901 100 100 400 400

# SSH
guivision ssh exec --ssh admin@192.168.64.100 "uname -a"
guivision ssh upload --ssh admin@192.168.64.100 local.txt /tmp/remote.txt
guivision ssh download --ssh admin@192.168.64.100 /tmp/remote.txt local.txt

# Video recording
guivision record --vnc localhost:5901 -o recording.mp4 --fps 30 --duration 10
```

All commands accept `--connect spec.json` for connection details from a JSON file, or individual `--vnc`, `--ssh`, and `--platform` flags.

### Key names

Letters: `a`-`z` | Digits: `0`-`9` | Special: `return` `enter` `tab` `escape` `esc` `space` `delete` `backspace` `forwarddelete` | Arrows: `up` `down` `left` `right` | Navigation: `home` `end` `pageup` `pagedown` | Function: `f1`-`f12`

### Modifier names

`cmd` `command` `alt` `option` `shift` `ctrl` `control` (mapped correctly per `--platform`)

### Mouse buttons

`left` `right` `middle` `center`

### Display resolution

VNC cannot change the display resolution. For tart VMs, use `tart set <vm> --display <width>x<height>` before or while the VM is running.

## Library

```swift
import GUIVisionVMDriver

// Connect
let capture = VNCCapture(host: "localhost", port: 5901, password: "secret")
try await capture.connect()

// Screen size
let size = await capture.screenSize() // CGSize?

// Screenshot
let image = try await capture.captureImage()
let png = try await capture.screenshot()

// Input
try await capture.withConnection { conn in
    VNCInput.typeText("Hello", connection: conn)
    try VNCInput.pressKey("return", platform: .macos, connection: conn)
    try VNCInput.click(x: 500, y: 400, connection: conn)

    // Fine-grained control
    try VNCInput.keyDown("shift", platform: .macos, connection: conn)
    try VNCInput.keyUp("shift", platform: .macos, connection: conn)
    try VNCInput.mouseDown(x: 100, y: 200, button: "left", connection: conn)
    try VNCInput.mouseUp(x: 300, y: 400, button: "left", connection: conn)
}

// SSH
let ssh = SSHClient(spec: SSHSpec(host: "192.168.64.100", user: "admin"))
let result = try ssh.exec("echo hello")
print(result.stdout) // "hello"

// Video recording
let recorder = StreamingCapture()
try await recorder.start(outputPath: "out.mp4", config: .init(width: 1920, height: 1080))
try await recorder.appendFrame(image)
try await recorder.stop()
```

## Integration Testing

Tests run against a real macOS VM via [tart](https://tart.run). A golden VM image provides a clean environment with SSH, Xcode CLI tools, and Homebrew pre-installed.

### First-time setup

Create the golden image (one-time, ~10 minutes):

```bash
scripts/vm-create-golden.sh
```

### Running tests

```bash
# One command — starts VM, runs tests, stops VM
scripts/test-integration.sh

# Watch tests run in a VNC viewer
scripts/test-integration.sh --viewer

# Keep VM running after tests (for debugging)
scripts/test-integration.sh --keep
```

### Interactive use

```bash
source scripts/vm-start.sh --viewer
swift test --filter IntegrationTests
# ... edit code, re-run tests ...
source scripts/vm-stop.sh
```

### Unit tests only (no VM needed)

```bash
swift test
```

## Scripts

| Script | How to run | What it does |
|--------|-----------|--------------|
| `scripts/vm-create-golden.sh` | `./scripts/vm-create-golden.sh` | Create golden VM image with SSH + Xcode + Homebrew |
| `scripts/test-integration.sh` | `./scripts/test-integration.sh` | Start VM, run integration tests, stop VM |
| `scripts/vm-start.sh` | `source scripts/vm-start.sh` | Start VM, set env vars in current shell |
| `scripts/vm-stop.sh` | `source scripts/vm-stop.sh` | Stop VM, clean env vars |

## Golden Image Contents

The golden image (`guivision-golden-tahoe`) includes:

- **macOS Tahoe** (Apple Silicon, via Cirrus Labs vanilla image)
- **SSH key auth** — host's SSH public key in `authorized_keys`, user `admin`
- **Xcode Command Line Tools** — `swift`, `clang`, `git`, `make`
- **Homebrew** — `/opt/homebrew/bin/brew`
- **Solid gray wallpaper** — clean background for screenshot analysis
- **No desktop widgets** — no visual clutter
- **Session restore disabled** — apps don't reopen old windows

## Requirements

- macOS 14+
- Swift 6.0
- [tart](https://tart.run) (for integration tests only)
- SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` (for golden image creation)

## LLM Integration

See [LLM_INSTRUCTIONS.md](LLM_INSTRUCTIONS.md) for complete instructions on using this project as a tool for LLM-driven automation.
