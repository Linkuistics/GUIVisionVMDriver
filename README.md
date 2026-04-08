# GUIVisionVMDriver

A Swift library and CLI for interacting with machines via VNC and in-VM accessibility agents. Designed for test automation, screenshot capture, video recording, and GUI-driven workflows.

## What It Does

**VNC capture and input:**
- Connect to any VNC server, capture screenshots (full or cropped), record video
- Query display dimensions
- Send keyboard events with platform-aware modifier mapping (Cmd/Alt/Ctrl work correctly on macOS, Windows, and Linux VMs)
- Individual key-down/key-up and mouse-down/mouse-up for fine-grained control
- Send mouse events: click, double-click, right-click, drag, scroll
- Type text with automatic handling of uppercase and shifted symbols
- Track cursor shape and position

**In-VM agent communication** (HTTP on port 8648):
- Accessibility tree access — query window lists, element snapshots, element inspection
- Semantic UI actions — press buttons, activate controls by role and label
- Command execution with stdout/stderr/exit code capture
- File upload and download

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

# OCR — find text on screen (captures VNC screenshot + runs Vision OCR locally)
guivision find-text --vnc localhost:5901 "Terminal"             # find text, return JSON with coords
guivision find-text --vnc localhost:5901 "Loading" --timeout 30 # poll until text appears (30s max)
guivision find-text --vnc localhost:5901                        # return all recognized text

# Agent — exec and file transfer
guivision exec --agent localhost:8648 "uname -a"
guivision upload --agent localhost:8648 local.txt /tmp/remote.txt
guivision download --agent localhost:8648 /tmp/remote.txt local.txt

# Agent — accessibility
guivision agent health --agent localhost:8648
guivision agent windows --agent localhost:8648
guivision agent snapshot --agent localhost:8648 --mode interact --window "Settings"
guivision agent inspect --agent localhost:8648 --role button --label "Save"
guivision agent press --agent localhost:8648 --role button --label "Save"

# Video recording
guivision record --vnc localhost:5901 -o recording.mp4 --fps 30 --duration 10
```

All commands accept `--connect spec.json` for connection details from a JSON file, or individual `--vnc`, `--agent`, and `--platform` flags.

### Key names

Letters: `a`-`z` | Digits: `0`-`9` | Special: `return` `enter` `tab` `escape` `esc` `space` `delete` `backspace` `forwarddelete` | Arrows: `up` `down` `left` `right` | Navigation: `home` `end` `pageup` `pagedown` | Function: `f1`-`f12`

### Modifier names

`cmd` `command` `alt` `option` `shift` `ctrl` `control` (mapped correctly per `--platform`)

### Mouse buttons

`left` `right` `middle` `center`

### Display resolution

VNC cannot change the display resolution. Use `--display WxH` when starting a VM:

```bash
source scripts/macos/vm-start.sh --display 1920x1080                      # macOS
source scripts/macos/vm-start.sh --platform windows --display 1920x1080   # Windows
```

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

// Agent communication
let agent = AgentTCPClient(host: "192.168.64.100", port: 8648)
let health = try await agent.health()
let snapshot = try await agent.snapshot(mode: "interact", window: "Settings")
let execResult = try await agent.exec(command: "uname -a")

// Video recording
let recorder = StreamingCapture()
try await recorder.start(outputPath: "out.mp4", config: .init(width: 1920, height: 1080))
try await recorder.appendFrame(image)
try await recorder.stop()
```

## Integration Testing

Tests run against a real macOS VM via [tart](https://tart.run). A golden VM image provides a clean environment with the in-VM agent, Xcode CLI tools, and Homebrew pre-installed.

### First-time setup

Create the golden image (one-time, ~10 minutes):

```bash
scripts/macos/vm-create-golden-macos.sh    # macOS (tart)
scripts/macos/vm-create-golden-linux.sh    # Linux (tart)
```

For Windows, first download the Windows 11 ARM64 ISO from
[Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64),
then pass it to the script:

```bash
scripts/macos/vm-create-golden-windows.sh --iso ~/Downloads/Win11_ARM64.iso
```

The ISO is cached after first use — subsequent runs don't need `--iso`.
The Windows installation is fully automated via `autounattend.xml`
(typical time: 20-40 minutes).

### Running tests

```bash
# Start a VM, run tests, stop when done
source scripts/macos/vm-start.sh --viewer                     # macOS (default)
source scripts/macos/vm-start.sh --platform linux --viewer     # Linux
source scripts/macos/vm-start.sh --platform windows --viewer   # Windows
swift test --package-path cli/macos --filter IntegrationTests
source scripts/macos/vm-stop.sh
```

### Unit tests only (no VM needed)

```bash
swift test --package-path cli/macos
```

## Scripts

| Script | How to run | What it does |
|--------|-----------|--------------|
| `scripts/macos/vm-create-golden-macos.sh` | `./scripts/macos/vm-create-golden-macos.sh` | Create macOS golden VM image (tart) with agent + Xcode + Homebrew |
| `scripts/macos/vm-create-golden-linux.sh` | `./scripts/macos/vm-create-golden-linux.sh` | Create Linux golden VM image (tart) with agent + dev tools |
| `scripts/macos/vm-create-golden-windows.sh` | `./scripts/macos/vm-create-golden-windows.sh --iso <path>` | Create Windows golden VM image (QEMU) with agent; requires downloaded ISO on first run |
| `scripts/macos/vm-start.sh` | `source scripts/macos/vm-start.sh` | Start VM, set env vars in current shell |
| `scripts/macos/vm-stop.sh` | `source scripts/macos/vm-stop.sh` | Stop VM, clean env vars |

### Environment variables

| Variable | Example | Description |
|----------|---------|-------------|
| `GUIVISION_AGENT` | `192.168.64.100:8648` | Agent HTTP endpoint |
| `GUIVISION_VNC` | `127.0.0.1:59948` | VNC endpoint |
| `GUIVISION_VNC_PASSWORD` | `syrup-rotate-nasty` | VNC password (tart only) |
| `GUIVISION_PLATFORM` | `macos` | Target platform (`macos`, `linux`, `windows`) |

## Golden Image Contents

### macOS (`guivision-golden-macos-tahoe`)

- **macOS Tahoe** (Apple Silicon, via Cirrus Labs vanilla image)
- **guivision-agent** — runs as LaunchAgent on port 8648, at `/usr/local/bin/guivision-agent`
- **TCC accessibility grant** — agent has accessibility permission via system TCC database (with code signing requirement); requires SIP disable/enable cycle during image creation
- **SSH key auth** — host's SSH public key in `authorized_keys`, user `admin` (used during golden image creation)
- **Xcode Command Line Tools** — `swift`, `clang`, `git`, `make`
- **Homebrew** — `/opt/homebrew/bin/brew`
- **Solid gray wallpaper** — clean background for screenshot analysis
- **No desktop widgets** — no visual clutter
- **Session restore disabled** — apps don't reopen old windows
- **SIP enabled** — standard security posture (SIP is temporarily disabled during image creation to write the TCC grant, then re-enabled)

### Linux (`guivision-golden-linux-24.04`)

- **Ubuntu 24.04 Desktop** (ARM64, via Cirrus Labs vanilla image + `ubuntu-desktop-minimal`)
- **guivision-agent** — runs as systemd user service on port 8648
- **AT-SPI2 accessibility enabled** — `python3-pyatspi` for accessibility bindings
- **xdotool** — window management fallback
- **SSH key auth** — host's SSH public key in `authorized_keys`, user `admin` (used during golden image creation)
- **GDM autologin** — boots directly to desktop as `admin`
- **Silent boot** — GRUB hidden, Plymouth splash, no text-mode console output
- **Solid gray wallpaper** — clean background for screenshot analysis
- **Screen lock and blanking disabled** — no interruptions during tests
- **Notifications disabled** — no visual clutter
- **NetworkManager** — configured via netplan (replaces systemd-networkd from base image)

### Windows (`guivision-golden-windows-11`)

- **Windows 11 Pro** (ARM64, installed from Microsoft evaluation ISO via QEMU)
- **guivision-agent** — runs as Task Scheduler logon task on port 8648
- **Chocolatey** — package manager for Windows dependencies
- **No SSH** — agent binary installed from autounattend media; all communication via agent HTTP
- **Autologin** — boots directly to desktop as `admin`
- **Solid gray wallpaper** — applied via Win32 API in desktop session
- **Widgets, search box, notifications disabled** — clean taskbar for vision pipeline
- **First-logon animation disabled** — clones boot straight to desktop without OOBE
- **UEFI + TPM 2.0** — standard Windows 11 secure boot via swtpm
- **VirtIO networking** — virtio-net-pci driver installed during setup

## Requirements

- macOS 14+
- Swift 6.0
- [tart](https://tart.run) — for macOS and Linux VMs
- [QEMU](https://www.qemu.org/) + [swtpm](https://github.com/stefanberger/swtpm) — for Windows VMs (`brew install qemu swtpm`)
- SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` (for macOS/Linux golden image creation — Windows does not use SSH)
- .NET 9+ SDK (for building Windows agent)
- Python 3.12+ (ships with Ubuntu desktop — for Linux agent)

## LLM Integration

See [LLM_INSTRUCTIONS.md](LLM_INSTRUCTIONS.md) for complete instructions on using this project as a tool for LLM-driven automation.
