# GUIVisionVMDriver — LLM Instructions

This document tells you everything you need to use the `guivision` CLI and GUIVisionVMDriver library to interact with a machine via VNC and SSH.

## What This Project Provides

`guivision` is a CLI tool (and Swift library) that connects to a machine over VNC to capture screenshots, send keyboard/mouse input, and record video. It also provides SSH command execution and file transfer. It does not manage VMs — you provide the VNC/SSH endpoints.

## CLI Reference

Every command requires at minimum `--vnc host:port`. Add `--platform macos|windows|linux` for correct modifier key mapping (defaults to macOS). SSH commands require `--ssh user@host[:port]`.

### Display

```bash
guivision screen-size --vnc host:port
# Output: 1920x1080
```

VNC cannot change display resolution. For tart VMs: `tart set <vm> --display WIDTHxHEIGHT`

### Screenshots

```bash
guivision screenshot --vnc host:port -o file.png
guivision screenshot --vnc host:port --region x,y,width,height -o file.png
```

### Keyboard

```bash
# Press and release a key (with optional modifiers)
guivision input key --vnc host:port KEYNAME
guivision input key --vnc host:port KEYNAME --modifiers mod1,mod2

# Hold/release a key separately
guivision input key-down --vnc host:port KEYNAME
guivision input key-up --vnc host:port KEYNAME

# Type a string (handles uppercase and shifted symbols automatically)
guivision input type --vnc host:port "text to type"
```

**Key names:** `a`-`z`, `0`-`9`, `return`, `enter`, `tab`, `escape`, `esc`, `space`, `delete`, `backspace`, `forwarddelete`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `f1`-`f12`

**Modifier names:** `cmd`, `command`, `alt`, `option`, `shift`, `ctrl`, `control`

**Platform modifier mapping:**
- macOS: `cmd` sends XK_Alt_L (maps to Cmd on Virtualization.framework VNC), `alt` sends XK_Meta_L
- Windows/Linux: `cmd` sends Ctrl, `alt` sends Alt, `super`/`win` sends Super

### Mouse

```bash
# Click (default: left button, single click)
guivision input click --vnc host:port X Y
guivision input click --vnc host:port X Y --button right
guivision input click --vnc host:port X Y --button left --count 2

# Press/release button separately
guivision input mouse-down --vnc host:port X Y [--button left|right|middle]
guivision input mouse-up --vnc host:port X Y [--button left|right|middle]

# Move cursor
guivision input move --vnc host:port X Y

# Scroll (negative dy = scroll up, positive = down)
guivision input scroll --vnc host:port X Y --dx 0 --dy -3

# Drag with interpolation
guivision input drag --vnc host:port fromX fromY toX toY [--button left] [--steps 10]
```

**Mouse buttons:** `left`, `right`, `middle`, `center`

### OCR Text Recognition

```bash
# Find text on the VNC screen (returns JSON array of matches with coordinates)
guivision find-text --vnc host:port "search text"

# Wait up to N seconds for text to appear (polls every 500ms)
guivision find-text --vnc host:port "Loading..." --timeout 30

# Return all recognized text on screen
guivision find-text --vnc host:port
```

Output is a JSON array:
```json
[{"text":"Terminal","x":248.0,"y":91.0,"width":55.0,"height":12.0,"confidence":0.95}]
```

Uses Apple Vision framework (`VNRecognizeTextRequest` with `.accurate` recognition level). Coordinates are in pixels with top-left origin, matching VNC input coordinates — click at `x + width/2`, `y + height/2` to hit the center of the text.

### SSH

```bash
# Execute a command (stdout to stdout, stderr to stderr, exit code propagated)
guivision ssh exec --ssh user@host "command"

# File transfer
guivision ssh upload --ssh user@host localpath remotepath
guivision ssh download --ssh user@host remotepath localpath
```

### Video Recording

```bash
guivision record --vnc host:port -o recording.mp4 --fps 30 --duration 10
guivision record --vnc host:port -o recording.mp4 --duration 0  # until Ctrl+C
guivision record --vnc host:port --region x,y,w,h -o cropped.mp4
```

### Connection Spec JSON

Instead of individual flags, pass `--connect spec.json`:

```json
{
    "vnc": { "host": "localhost", "port": 5900, "password": "secret" },
    "ssh": { "host": "192.168.64.100", "port": 22, "user": "admin" },
    "platform": "macos"
}
```

## Using the Library

Add as a Swift Package dependency:

```swift
.package(path: "../GUIVisionVMDriver")
```

Then `import GUIVisionVMDriver`:

```swift
// Connect to VNC
let capture = VNCCapture(host: "localhost", port: 5901, password: "secret")
try await capture.connect()

// Query screen
let size = await capture.screenSize() // CGSize?

// Screenshot
let image: CGImage = try await capture.captureImage()
let cropped = try await capture.captureImage(region: CGRect(x: 0, y: 0, width: 800, height: 600))
let pngData: Data = try await capture.screenshot()

// Keyboard and mouse (requires withConnection for VNCConnection access)
try await capture.withConnection { conn in
    // High-level
    VNCInput.typeText("Hello World!", connection: conn)
    try VNCInput.pressKey("return", platform: .macos, connection: conn)
    try VNCInput.pressKey("a", modifiers: ["cmd"], platform: .macos, connection: conn)
    try VNCInput.click(x: 500, y: 400, connection: conn)
    try VNCInput.click(x: 500, y: 400, button: "right", count: 1, connection: conn)
    VNCInput.scroll(x: 500, y: 400, deltaX: 0, deltaY: -3, connection: conn)
    try VNCInput.drag(fromX: 100, fromY: 100, toX: 400, toY: 400, connection: conn)

    // Low-level
    try VNCInput.keyDown("shift", platform: .macos, connection: conn)
    try VNCInput.keyUp("shift", platform: .macos, connection: conn)
    try VNCInput.mouseDown(x: 100, y: 200, button: "left", connection: conn)
    VNCInput.mouseMove(x: 200, y: 300, connection: conn)
    try VNCInput.mouseUp(x: 200, y: 300, button: "left", connection: conn)
}

// Cursor state (shape, position — depends on server support)
let cursor = await capture.cursorState

// OCR text recognition
let image = try await capture.captureImage()
let matches = TextRecognizer.recognizeText(in: image)
// Each match: TextMatch(text: "Terminal", x: 248, y: 91, width: 55, height: 12, confidence: 0.95)

// SSH
let ssh = SSHClient(spec: SSHSpec(host: "192.168.64.100", user: "admin"))
let result = try ssh.exec("echo hello")
// result.stdout, result.stderr, result.exitCode, result.succeeded

try ssh.upload(localPath: "/tmp/file.txt", remotePath: "/tmp/remote.txt")
try ssh.download(remotePath: "/tmp/remote.txt", localPath: "/tmp/local.txt")

// Video recording
let recorder = StreamingCapture()
try await recorder.start(outputPath: "out.mp4", config: StreamingCaptureConfig(width: 1920, height: 1080, fps: 30))
for _ in 0..<100 {
    let frame = try await capture.captureImage()
    try await recorder.appendFrame(frame)
}
try await recorder.stop()

// Disconnect
await capture.disconnect()
```

## VM Management with tart

This project does not manage VMs. Use [tart](https://tart.run) directly:

```bash
# List VMs
tart list

# Clone and start a VM
tart clone guivision-golden-macos-tahoe my-test-vm
tart run my-test-vm --no-graphics --vnc-experimental > /tmp/vnc.txt 2>&1 &

# Parse VNC URL from tart's stdout (format: vnc://:password@host:port)
VNC_URL=$(grep -o 'vnc://[^ ]*' /tmp/vnc.txt | head -1 | sed 's/\.\.\.$//')
VNC_HOST=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\3|')
VNC_PORT=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\4|')
VNC_PASS=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?.*|\2|')

# Get VM IP for SSH
VM_IP=$(tart ip my-test-vm)

# Change display resolution (before or while running)
tart set my-test-vm --display 1920x1080

# Stop and delete
tart stop my-test-vm
tart delete my-test-vm
```

## Convenience Scripts

These scripts automate common tart workflows for this project's integration tests:

```bash
# Create golden VM image (one-time, ~10 min)
scripts/vm-create-golden-macos.sh    # macOS (tart): SSH key auth, Xcode CLI tools, Homebrew, solid wallpaper
scripts/vm-create-golden-linux.sh    # Linux (tart): SSH key auth, dev tools, solid wallpaper
scripts/vm-create-golden-windows.sh --iso ~/Downloads/Win11_ARM64.iso  # Windows (QEMU): needs ISO from microsoft.com/en-us/software-download/windows11arm64

# Run integration tests (starts VM, tests, stops VM)
scripts/test-integration.sh
scripts/test-integration.sh --viewer    # watch in VNC viewer

# Interactive: keep VM running between test iterations
source scripts/vm-start.sh --viewer
swift test --filter IntegrationTests
source scripts/vm-stop.sh
```

### Environment variables set by the scripts

| Variable | Example | Description |
|----------|---------|-------------|
| `GUIVISION_VNC` | `127.0.0.1:59948` | VNC endpoint |
| `GUIVISION_VNC_PASSWORD` | `syrup-rotate-nasty` | VNC password |
| `GUIVISION_SSH` | `admin@192.168.64.100` | SSH endpoint |
| `GUIVISION_PLATFORM` | `macos` | Platform hint |

## Golden Image Contents

The macOS golden image (`guivision-golden-macos-tahoe`) provides:

- **macOS Tahoe** on Apple Silicon
- **User:** `admin` with SSH key auth (host's public key in `authorized_keys`)
- **Xcode Command Line Tools:** `swift`, `swiftc`, `clang`, `git`, `make`, `ld`
- **Homebrew:** `/opt/homebrew/bin/brew` (in PATH via `.zprofile`)
- **guivision-agent** at `/usr/local/bin/guivision-agent` — in-VM accessibility agent for GUI automation (window listing, element inspection, screenshots, actions)
- **TCC accessibility grant** — agent has system-level accessibility permission (written to TCC database with code signing requirement during a SIP disable/enable cycle)
- **SIP enabled** — standard security posture after image creation
- **Desktop:** solid gray wallpaper, no widgets, no Terminal, session restore disabled

You can compile and run Swift code, install packages with Homebrew, and use standard Unix tools inside the VM via SSH. The guivision-agent provides accessibility APIs for GUI testing when launched in a desktop session context.

## Writing Test Scripts

When writing a script that tests GUI behavior on a macOS VM:

1. **Start a VM** using tart or the convenience scripts
2. **Use `guivision screenshot`** to capture the screen and verify visual state
3. **Use `guivision input`** to send keyboard/mouse events
4. **Use `guivision ssh exec`** to run commands inside the VM and verify results
5. **Use `guivision screen-size`** to know the display dimensions before clicking
6. **Clean up** by stopping and deleting the VM

### Example: verify typing reaches an application

```bash
# Start VM
source scripts/vm-start.sh

# Open Terminal inside the VM
guivision ssh exec --ssh "$GUIVISION_SSH" "open -a Terminal"
sleep 5

# Click on Terminal window to focus it
SIZE=$(guivision screen-size --vnc "$GUIVISION_VNC")
CX=$((${SIZE%x*} / 2))
CY=$((${SIZE#*x} / 2))
guivision input click --vnc "$GUIVISION_VNC" $CX $CY
sleep 1

# Type a command
guivision input type --vnc "$GUIVISION_VNC" "echo hello > /tmp/test.txt"
guivision input key --vnc "$GUIVISION_VNC" return
sleep 2

# Verify via SSH
RESULT=$(guivision ssh exec --ssh "$GUIVISION_SSH" "cat /tmp/test.txt")
echo "Got: $RESULT"

source scripts/vm-stop.sh
```

### Tips

- After sending keyboard input, add `sleep` for the VM to process events
- VNC cursor is a separate overlay — it doesn't appear in screenshots
- Use `screen-size` to compute click coordinates relative to the display
- Use `find-text` to locate UI elements by their text content instead of hardcoded coordinates
- The `--platform` flag affects modifier key mapping — use `macos` for tart VMs
- SSH key auth only; password auth is not supported by the SSH client
- `AXIsProcessTrusted()` returns false when the agent is run via SSH (macOS "responsible client" audit session issue) — the TCC grant works correctly when the agent is launched by launchd in a desktop session

## Connection Caching (Server Mode)

The CLI transparently manages a background server process that holds persistent VNC and SSH connections. This eliminates per-command connection overhead when running multiple commands in sequence.

### How it works

1. The first `guivision` command auto-starts a background server process that connects to the VNC/SSH endpoints
2. Subsequent commands reuse the existing server — no reconnection needed
3. The server self-terminates after 300 seconds (5 minutes) of inactivity
4. Different connection targets (different `--vnc`/`--ssh` values) get independent server instances

### What this means for scripts

- Rapid command sequences are much faster (only the first command pays the connection cost)
- No user action is required — server lifecycle is fully automatic
- The server communicates via a Unix domain socket at `/tmp/guivision-<hash>.sock`
- If a server process crashes or is killed, the next command auto-starts a fresh one

### Recording limits

When recording via the server, duration is required and capped at 300 seconds (5 minutes). Specifying `--duration 0` uses the 300-second cap. This prevents orphaned recording processes.
