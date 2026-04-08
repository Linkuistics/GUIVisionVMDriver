# GUIVisionVMDriver — LLM Instructions

## Architecture

Two independent channels to each VM:

| Channel | Transport | Purpose | Endpoint |
|---------|-----------|---------|----------|
| **VNC** | RFB protocol | Screenshots, keyboard/mouse input, video recording | `--vnc host:port` |
| **Agent** | HTTP/1.1 JSON on port 8648 | Accessibility tree, UI actions, exec, file transfer, shutdown | `--agent host:port` |

Each VM runs an agent HTTP server on port 8648. The host CLI (`guivision`) talks to both channels. VNC is the visual/input channel; agent is the semantic/exec channel.

**Platform agents:** macOS (Swift/Hummingbird), Windows (C#/ASP.NET), Linux (Python/http.server). All expose identical HTTP endpoints.

## Quick Reference

### Start a VM

```bash
source scripts/macos/vm-start.sh                                          # macOS (default)
source scripts/macos/vm-start.sh --platform linux                         # Linux
source scripts/macos/vm-start.sh --platform windows                       # Windows
source scripts/macos/vm-start.sh --platform windows --display 1920x1080   # Windows at 1920x1080
```

Sets: `GUIVISION_VNC`, `GUIVISION_VNC_PASSWORD`, `GUIVISION_AGENT`, `GUIVISION_PLATFORM`

### Multi-VM Setup

Run multiple VMs simultaneously — each gets its own endpoints:

```bash
source scripts/macos/vm-start.sh --name vm1                           # macOS
MAC_VNC="$GUIVISION_VNC" MAC_AGENT="$GUIVISION_AGENT"

source scripts/macos/vm-start.sh --platform linux --name vm2          # Linux
LINUX_VNC="$GUIVISION_VNC" LINUX_AGENT="$GUIVISION_AGENT"

source scripts/macos/vm-start.sh --platform windows --name vm3        # Windows
WIN_VNC="$GUIVISION_VNC" WIN_AGENT="$GUIVISION_AGENT"

# Now interact with each independently:
guivision exec --agent "$MAC_AGENT" "uname -a"
guivision exec --agent "$LINUX_AGENT" "uname -a"
guivision exec --agent "$WIN_AGENT" "systeminfo | findstr /B /C:\"OS Name\""

# VMs on the same tart network can reach each other via IP:
MAC_IP=$(echo "$MAC_AGENT" | cut -d: -f1)
guivision exec --agent "$LINUX_AGENT" "curl -sf http://$MAC_IP:8648/health"
```

### Stop VMs

```bash
source scripts/macos/vm-stop.sh            # stops the last-started VM
source scripts/macos/vm-stop.sh --name vm1 # stops a specific VM
```

## Agent Commands

### Exec & File Transfer

```bash
guivision exec --agent host:port "command"                  # run shell command
guivision upload --agent host:port localpath remotepath      # upload file
guivision download --agent host:port remotepath localpath    # download file
```

### Accessibility

```bash
guivision agent health --agent host:port                    # check agent + accessibility status
guivision agent windows --agent host:port                   # list all windows
guivision agent snapshot --agent host:port [options]        # accessibility tree snapshot
guivision agent inspect --agent host:port [query]           # detailed element properties + bounds
```

Snapshot options: `--mode interact|layout|full`, `--window FILTER`, `--role ROLE`, `--label TEXT`, `--depth N`

### UI Actions

```bash
guivision agent press --agent host:port [query]             # press/click element
guivision agent set-value --agent host:port [query] --value TEXT  # set text/slider value
guivision agent focus --agent host:port [query]             # focus element
guivision agent show-menu --agent host:port [query]         # open context menu
```

Query parameters: `--role ROLE`, `--label TEXT`, `--window FILTER`, `--id ID`, `--index N`

### Window Management

```bash
guivision agent window-focus --agent host:port --window FILTER
guivision agent window-resize --agent host:port --window FILTER --width W --height H
guivision agent window-move --agent host:port --window FILTER --x X --y Y
guivision agent window-close --agent host:port --window FILTER
guivision agent window-minimize --agent host:port --window FILTER
guivision agent wait --agent host:port [--timeout SECONDS]
```

## VNC Commands

### Screenshots & Display

```bash
guivision screen-size --vnc host:port                       # "1920x1080"
guivision screenshot --vnc host:port -o file.png            # full screen
guivision screenshot --vnc host:port --region x,y,w,h -o file.png  # cropped
```

### Keyboard

```bash
guivision input key --vnc host:port KEYNAME [--modifiers mod1,mod2]
guivision input key-down --vnc host:port KEYNAME            # hold key
guivision input key-up --vnc host:port KEYNAME              # release key
guivision input type --vnc host:port "text to type"         # type string
```

Keys: `a`-`z` `0`-`9` `return` `tab` `escape` `space` `delete` `backspace` `forwarddelete` `up` `down` `left` `right` `home` `end` `pageup` `pagedown` `f1`-`f12`
Modifiers: `cmd` `alt` `shift` `ctrl` — mapped per `--platform`

### Mouse

```bash
guivision input click --vnc host:port X Y [--button right] [--count 2]
guivision input mouse-down --vnc host:port X Y [--button left|right|middle]
guivision input mouse-up --vnc host:port X Y
guivision input move --vnc host:port X Y
guivision input scroll --vnc host:port X Y --dy -3          # negative = up
guivision input drag --vnc host:port fromX fromY toX toY
```

### OCR

```bash
guivision find-text --vnc host:port "search text"           # find text, returns JSON with coords
guivision find-text --vnc host:port "Loading" --timeout 30  # poll until found
guivision find-text --vnc host:port                         # all text on screen
```

Returns: `[{"text":"Terminal","x":248,"y":91,"width":55,"height":12,"confidence":0.95}]`
Click center: `x + width/2`, `y + height/2`

### Video Recording

```bash
guivision record --vnc host:port -o out.mp4 --fps 30 --duration 10
```

## Connection Spec JSON

```json
{"vnc": {"host": "localhost", "port": 5900, "password": "secret"},
 "agent": {"host": "192.168.64.100", "port": 8648},
 "platform": "macos"}
```

Pass via `--connect spec.json` instead of individual flags.

## Workflow Patterns

### Discover-then-act (preferred)

```bash
# 1. See what's on screen semantically
guivision agent snapshot --agent "$GUIVISION_AGENT" --mode interact

# 2. Act on elements by role/label (not pixel coordinates)
guivision agent press --agent "$GUIVISION_AGENT" --role button --label "Save"

# 3. Verify result
guivision agent snapshot --agent "$GUIVISION_AGENT" --mode interact
```

### Visual verification

```bash
# Screenshot + OCR for visual properties (colors, layout, rendered text)
guivision screenshot --vnc "$GUIVISION_VNC" -o screen.png
guivision find-text --vnc "$GUIVISION_VNC" "Expected text"
```

### Cross-VM communication

```bash
# Start a server in VM1, connect from VM2
guivision exec --agent "$VM1_AGENT" "python3 -m http.server 9000 &"
VM1_IP=$(echo "$VM1_AGENT" | cut -d: -f1)
guivision exec --agent "$VM2_AGENT" "curl -sf http://$VM1_IP:9000/"
```

### Install and test software

```bash
# macOS
guivision exec --agent "$GUIVISION_AGENT" "brew install jq"

# Linux
guivision exec --agent "$GUIVISION_AGENT" "sudo apt-get install -y jq"

# Windows
guivision exec --agent "$GUIVISION_AGENT" "choco install jq -y"
```

## Golden Images

Pre-built VM images with clean desktops, agent pre-installed, auto-login enabled.

| Image | Hypervisor | User | Agent Autostart | Package Manager |
|-------|-----------|------|-----------------|-----------------|
| `guivision-golden-macos-tahoe` | tart | admin | LaunchAgent | Homebrew |
| `guivision-golden-linux-24.04` | tart | admin | systemd user service | apt |
| `guivision-golden-windows-11` | QEMU | admin | Task Scheduler | Chocolatey |

All images: solid gray wallpaper, no notifications/widgets, accessibility enabled, agent on port 8648.

### Create golden images (one-time)

```bash
scripts/macos/vm-create-golden-macos.sh
scripts/macos/vm-create-golden-linux.sh
scripts/macos/vm-create-golden-windows.sh --iso ~/Downloads/Win11_ARM64.iso
```

## Tips

- **Prefer accessibility over coordinates**: `--role button --label "Save"` is more robust than clicking at pixel (x, y)
- **Use `find-text` for visual elements**: OCR finds rendered text that accessibility can't see (images, canvas, custom-drawn UI)
- **Sleep after input**: VMs need time to process events — `sleep 1` after keyboard/mouse, `sleep 5` after launching apps
- **Multi-VM networking**: tart VMs share a network bridge; QEMU uses NAT with port forwarding. tart VMs can reach each other by IP; QEMU VMs need explicit port forwards
- **Display resolution**: `--display 1920x1080` sets VM display size. Works for all platforms (tart uses `tart set --display`, QEMU uses `virtio-gpu-pci` xres/yres)
- **Platform modifiers**: `--platform macos` maps `cmd` to macOS Command key; `--platform windows` maps `cmd` to Ctrl
- **Connection caching**: The first `guivision` command auto-starts a background VNC server process. Subsequent commands reuse it. Idle timeout: 5 minutes.
- **Agent is the primary channel**: Use agent exec instead of SSH. VNC is for visual verification and keyboard/mouse when accessibility can't target an element.
