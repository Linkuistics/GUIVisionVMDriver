# VM Scripts for Integration Testing

These scripts manage tart macOS VMs for running GUIVisionVMDriver integration tests. They must be `source`d (not executed) so environment variables persist in your shell.

## Quick Start

```bash
# First time: create the golden image (~10 min, one-time)
scripts/vm-create-golden.sh

# Run integration tests
scripts/test-integration.sh

# Run with VNC viewer open to watch
scripts/test-integration.sh --viewer
```

## vm-create-golden.sh

Creates a golden macOS VM image from Cirrus Labs' vanilla image. Run once — subsequent test runs clone from this image.

```bash
scripts/vm-create-golden.sh [--version tahoe|sequoia|sonoma] [--name NAME]
```

**What the golden image includes:**
- SSH key auth (host's `~/.ssh/id_ed25519.pub` or `id_rsa.pub` in `authorized_keys`)
- Xcode Command Line Tools (`swift`, `clang`, `git`, `make`)
- Homebrew (`/opt/homebrew/bin/brew`)
- Solid gray wallpaper (no distracting background for screenshot analysis)
- Desktop widgets hidden
- Session restore disabled (Terminal won't reopen old windows)
- User: `admin` (SSH key auth, no password needed)

## test-integration.sh

One command to run integration tests. Starts a VM, runs tests, stops the VM.

```bash
scripts/test-integration.sh [options]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--base IMAGE` | `guivision-golden-tahoe` | Base image to clone from |
| `--viewer` | off | Open VNC viewer to watch tests |
| `--keep` | off | Don't stop VM after tests (for debugging) |
| `--no-ssh` | off | Skip SSH tests |
| `--filter EXPR` | `IntegrationTests` | Swift test filter |

If the golden image doesn't exist, offers to create it.

## vm-start.sh / vm-stop.sh

For interactive use — keep a VM running between test iterations.

```bash
source scripts/vm-start.sh [--viewer] [--base IMAGE]
swift test --filter IntegrationTests
# ... iterate ...
source scripts/vm-stop.sh
```

## Prerequisites

- [tart](https://tart.run) installed at `/opt/homebrew/bin/tart`
- SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`

## Environment Variables

Set by `vm-start.sh` and `test-integration.sh`:

| Variable | Example | Description |
|----------|---------|-------------|
| `GUIVISION_TEST_VNC` | `127.0.0.1:59948` | VNC endpoint |
| `GUIVISION_TEST_VNC_PASSWORD` | `syrup-rotate-nasty` | VNC password |
| `GUIVISION_TEST_SSH` | `admin@192.168.64.100` | SSH endpoint |
| `GUIVISION_TEST_PLATFORM` | `macos` | Platform hint for keysym mapping |

You can set these manually to test against any VNC/SSH target without using the scripts.

## For LLMs Writing Test Scripts

The golden image has Xcode CLI tools, Homebrew, and SSH — you can compile and run code inside the VM.

**Option 1: Use these scripts**
```bash
source scripts/vm-start.sh
# GUIVISION_TEST_VNC and GUIVISION_TEST_SSH are now set

# Take a screenshot
guivision screenshot --vnc "$GUIVISION_TEST_VNC" -o screen.png

# Type text via VNC
guivision input type --vnc "$GUIVISION_TEST_VNC" "Hello"

# Run a command via SSH
guivision ssh exec --vnc "$GUIVISION_TEST_VNC" --ssh "$GUIVISION_TEST_SSH" "echo hi"

# Compile and run code inside the VM
guivision ssh exec --ssh "$GUIVISION_TEST_SSH" "swift --version"
guivision ssh exec --ssh "$GUIVISION_TEST_SSH" "brew install jq"

source scripts/vm-stop.sh
```

**Option 2: Manage tart directly**
```bash
tart clone guivision-golden-tahoe my-test-vm
tart run my-test-vm --no-graphics --vnc-experimental > /tmp/vnc.txt 2>&1 &

# Parse VNC URL from tart output
VNC_URL=$(grep -o 'vnc://[^ ]*' /tmp/vnc.txt | head -1 | sed 's/\.\.\.$//')
# ... extract host, port, password from URL ...

VM_IP=$(tart ip my-test-vm)
export GUIVISION_TEST_VNC="$VNC_HOST:$VNC_PORT"
export GUIVISION_TEST_SSH="admin@$VM_IP"

# Use guivision CLI or run swift test
swift test --filter IntegrationTests

tart stop my-test-vm && tart delete my-test-vm
```
