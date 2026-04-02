# VM Scripts for Integration Testing

These scripts manage tart macOS VMs for running GUIVisionVMDriver integration tests. They must be `source`d (not executed) so environment variables persist in your shell.

## Quick Start

```bash
source scripts/vm-start.sh
swift test --filter IntegrationTests
source scripts/vm-stop.sh
```

## vm-start.sh

Clones a tart VM from a base image, starts it with VNC, waits for SSH, and exports the environment variables that integration tests expect.

```bash
source scripts/vm-start.sh [options]
```

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--base IMAGE` | `testanyware-golden-tahoe` | Base image to clone from |
| `--name NAME` | `guivision-inttest` | VM name |
| `--viewer` | off | Open macOS VNC viewer with auto-typed password |
| `--no-ssh` | off | Skip waiting for SSH (only VNC tests will run) |

**Environment variables set:**

| Variable | Example | Description |
|----------|---------|-------------|
| `GUIVISION_TEST_VNC` | `127.0.0.1:59948` | VNC endpoint (required for VNC tests) |
| `GUIVISION_TEST_VNC_PASSWORD` | `syrup-rotate-nasty` | VNC password from tart |
| `GUIVISION_TEST_SSH` | `admin@192.168.64.100` | SSH endpoint (required for SSH tests) |
| `GUIVISION_TEST_PLATFORM` | `macos` | Platform hint for keysym mapping |
| `GUIVISION_VM_NAME` | `guivision-inttest` | VM name (used by vm-stop.sh) |
| `GUIVISION_VM_PID` | `12345` | tart process PID |

## vm-stop.sh

Stops the VM, closes the VNC viewer if open, deletes the VM, and unsets all environment variables.

```bash
source scripts/vm-stop.sh
```

## Prerequisites

- [tart](https://tart.run) installed at `/opt/homebrew/bin/tart`
- A base VM image (e.g. `testanyware-golden-tahoe`) with SSH enabled and the host's SSH key authorized

## Using a Custom VNC Target

You don't need these scripts if you already have a VNC endpoint. Just set the env vars directly:

```bash
export GUIVISION_TEST_VNC=myhost:5900
export GUIVISION_TEST_VNC_PASSWORD=secret
export GUIVISION_TEST_SSH=admin@myhost
export GUIVISION_TEST_PLATFORM=macos
swift test --filter IntegrationTests
```

## For LLMs Writing Test Scripts

If you're an LLM writing a test script that needs a VM, you have two options:

**Option 1: Use these scripts** (if a suitable base image exists)
```bash
source scripts/vm-start.sh --base testanyware-golden-tahoe
# GUIVISION_TEST_VNC and GUIVISION_TEST_SSH are now set
swift test --filter IntegrationTests
source scripts/vm-stop.sh
```

**Option 2: Manage tart directly** (for custom VM setup)
```bash
# Clone and start
tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest my-test-vm
tart run my-test-vm --no-graphics --vnc-experimental > /tmp/vnc.txt 2>&1 &

# Parse VNC URL from tart output
VNC_URL=$(grep -o 'vnc://[^ ]*' /tmp/vnc.txt | head -1 | sed 's/\.\.\.$//')
VNC_HOST=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\3|')
VNC_PORT=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\4|')
VNC_PASS=$(echo "$VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?.*|\2|')

# Get VM IP for SSH
VM_IP=$(tart ip my-test-vm)

# Set env vars
export GUIVISION_TEST_VNC="$VNC_HOST:$VNC_PORT"
export GUIVISION_TEST_VNC_PASSWORD="$VNC_PASS"
export GUIVISION_TEST_SSH="admin@$VM_IP"
export GUIVISION_TEST_PLATFORM=macos

# Use guivision CLI
guivision screenshot --vnc "$GUIVISION_TEST_VNC" -o screen.png
guivision input type --vnc "$GUIVISION_TEST_VNC" "Hello"
guivision ssh exec --vnc "$GUIVISION_TEST_VNC" --ssh "$GUIVISION_TEST_SSH" "echo hi"

# Clean up
tart stop my-test-vm
tart delete my-test-vm
```
