#!/bin/bash
# Run integration tests against a tart or QEMU VM.
# Starts the VM, runs Swift tests, then cleans up.
#
# Usage:
#   scripts/test-integration.sh [options]
#
# Options:
#   --platform PLATFORM  Target platform: macos|linux|windows (default: macos)
#   --base IMAGE         Base image to clone from (default: platform-specific)
#   --name NAME          VM name / clone identifier (default: guivision-inttest)
#   --viewer             Open VNC viewer to watch tests run
#   --no-ssh             Skip waiting for SSH
#   --keep               Don't stop the VM after tests (for debugging)
#   --filter EXPR        Swift test filter (default: IntegrationTests)
#
# Platform defaults for --base:
#   macos   → guivision-golden-macos-tahoe
#   linux   → guivision-golden-linux-24.04
#   windows → guivision-golden-windows-11
#
# Exported env vars (consumed by Swift integration tests):
#   GUIVISION_VNC=host:port
#   GUIVISION_VNC_PASSWORD=...           (tart only)
#   GUIVISION_SSH=admin@ip               (unless --no-ssh; QEMU: admin@localhost -p 2222)
#   GUIVISION_PLATFORM=macos|linux|windows
#   GUIVISION_VM_TOOL=tart|qemu

set -eu
cd "$(dirname "$0")/.."

_PLATFORM="macos"
_BASE=""
_NAME="guivision-inttest"
_VIEWER=false
_SSH=true
_SSH_USER="admin"
_KEEP=false
_FILTER="IntegrationTests"
_TOOL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) _PLATFORM="$2"; shift 2 ;;
        --base)     _BASE="$2"; shift 2 ;;
        --name)     _NAME="$2"; shift 2 ;;
        --viewer)   _VIEWER=true; shift ;;
        --no-ssh)   _SSH=false; shift ;;
        --keep)     _KEEP=true; shift ;;
        --filter)   _FILTER="$2"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Set platform-specific defaults
case "$_PLATFORM" in
    macos)
        [[ -z "$_BASE" ]] && _BASE="guivision-golden-macos-tahoe"
        _TOOL="tart"
        ;;
    linux)
        [[ -z "$_BASE" ]] && _BASE="guivision-golden-linux-24.04"
        _TOOL="tart"
        ;;
    windows)
        [[ -z "$_BASE" ]] && _BASE="guivision-golden-windows-11"
        _TOOL="qemu"
        ;;
    *)
        echo "ERROR: Unknown platform '$_PLATFORM'. Must be macos, linux, or windows."
        exit 1
        ;;
esac

# --- VM Lifecycle ---

cleanup() {
    if $_KEEP; then
        echo ""
        echo "VM '$_NAME' kept running (--keep). To stop:"
        if [[ "$_TOOL" == "tart" ]]; then
            echo "  tart stop $_NAME && tart delete $_NAME"
        else
            echo "  kill \$GUIVISION_VM_PID"
            echo "  rm -rf $HOME/.guivision/clones/$_NAME"
        fi
        return
    fi

    # Close VNC viewer window by ID
    if [[ -n "${_WINDOW_ID:-}" ]] && pgrep -q "Screen Sharing"; then
        osascript -e "
            tell application \"System Events\"
                tell process \"Screen Sharing\"
                    repeat with w in every window
                        if value of attribute \"AXIdentifier\" of w is \"$_WINDOW_ID\" then
                            click (first button of w whose subrole is \"AXCloseButton\")
                            exit repeat
                        end if
                    end repeat
                end tell
            end tell
        " 2>/dev/null || true
        sleep 0.5
    fi

    if [[ "$_TOOL" == "tart" ]]; then
        echo "Stopping VM '$_NAME'..."
        tart stop "$_NAME" 2>/dev/null || true
        tart delete "$_NAME" 2>/dev/null || true
        if [[ -n "${_TART_PID:-}" ]] && kill -0 "$_TART_PID" 2>/dev/null; then
            kill "$_TART_PID" 2>/dev/null
            wait "$_TART_PID" 2>/dev/null
        fi
    else
        echo "Stopping QEMU VM '$_NAME'..."
        if [[ -n "${_QEMU_PID:-}" ]] && kill -0 "$_QEMU_PID" 2>/dev/null; then
            kill "$_QEMU_PID" 2>/dev/null
            wait "$_QEMU_PID" 2>/dev/null || true
        fi
        # Kill swtpm process associated with this clone's socket
        _TPM_SOCKET="$HOME/.guivision/clones/$_NAME/$_NAME-tpm/swtpm-sock"
        pkill -f "swtpm.*path=$_TPM_SOCKET" 2>/dev/null || true
        # Remove clone directory
        _CLONE_DIR="$HOME/.guivision/clones/$_NAME"
        if [[ -d "$_CLONE_DIR" ]]; then
            rm -rf "$_CLONE_DIR"
        fi
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Tart path (macOS / Linux)
# ---------------------------------------------------------------------------

if [[ "$_TOOL" == "tart" ]]; then

    # Check base image exists, offer to create if missing
    _VM_LIST=$(tart list --format json 2>/dev/null || echo "[]")
    if ! echo "$_VM_LIST" | grep -q "\"$_BASE\""; then
        echo "Base image '$_BASE' not found."
        case "$_PLATFORM" in
            macos)  _CREATE_SCRIPT="scripts/vm-create-golden-macos.sh" ;;
            linux)  _CREATE_SCRIPT="scripts/vm-create-golden-linux.sh" ;;
        esac
        echo "Create it with: $_CREATE_SCRIPT"
        echo ""
        read -p "Create it now? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$_CREATE_SCRIPT"
            _VM_LIST=$(tart list --format json 2>/dev/null || echo "[]")
        else
            exit 1
        fi
    fi

    # Stop existing VM if running
    if echo "$_VM_LIST" | grep -q "\"$_NAME\""; then
        echo "Stopping existing VM '$_NAME'..."
        tart stop "$_NAME" 2>/dev/null || true
        sleep 2
        tart delete "$_NAME" 2>/dev/null || true
    fi

    # Clone and start
    echo "Cloning $_BASE → $_NAME..."
    tart clone "$_BASE" "$_NAME"

    _VNC_OUTPUT=$(mktemp)
    tart run "$_NAME" --no-graphics --vnc-experimental > "$_VNC_OUTPUT" 2>&1 &
    _TART_PID=$!

    # Wait for VNC URL
    echo "Waiting for VNC..."
    _VNC_URL=""
    for i in $(seq 1 60); do
        _VNC_URL=$(grep -o 'vnc://[^ ]*' "$_VNC_OUTPUT" 2>/dev/null | head -1 | sed 's/\.\.\.$//' || true)
        if [[ -n "$_VNC_URL" ]]; then break; fi
        sleep 1
    done
    rm -f "$_VNC_OUTPUT"

    if [[ -z "$_VNC_URL" ]]; then
        echo "ERROR: VM did not produce a VNC URL within 60s"
        exit 1
    fi

    _VNC_HOST=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\3|')
    _VNC_PORT=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\4|')
    _VNC_PASS=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?.*|\2|')

    echo "VNC: $_VNC_HOST:$_VNC_PORT"

    export GUIVISION_VNC="$_VNC_HOST:$_VNC_PORT"
    export GUIVISION_VNC_PASSWORD="$_VNC_PASS"
    export GUIVISION_PLATFORM="$_PLATFORM"
    export GUIVISION_VM_TOOL="tart"

    # Wait for SSH
    if $_SSH; then
        echo "Waiting for VM IP..."
        _IP=""
        for i in $(seq 1 30); do
            _IP=$(tart ip "$_NAME" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$_IP" ]]; then break; fi
            sleep 2
        done

        if [[ -n "$_IP" ]]; then
            echo "Waiting for SSH at $_SSH_USER@$_IP..."
            for i in $(seq 1 40); do
                if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                       -o LogLevel=ERROR -o ConnectTimeout=5 \
                       "$_SSH_USER@$_IP" "echo ok" &>/dev/null; then
                    export GUIVISION_SSH="$_SSH_USER@$_IP"
                    echo "SSH: $_SSH_USER@$_IP"
                    break
                fi
                sleep 3
            done
        fi

        if [[ -z "${GUIVISION_SSH:-}" ]]; then
            echo "WARNING: SSH not available — SSH tests will be skipped"
        fi
    fi

    # Open VNC viewer
    _WINDOW_ID=""
    if $_VIEWER; then
        echo "Opening VNC viewer..."
        open "$_VNC_URL"
        if [[ -n "$_VNC_PASS" ]]; then
            sleep 2
            osascript -e "
                tell application \"System Events\"
                    keystroke \"$_VNC_PASS\"
                    keystroke return
                end tell
            " 2>/dev/null || true
        fi
        sleep 1
        _WINDOW_ID=$(osascript -e '
            tell application "System Events"
                tell process "Screen Sharing"
                    return value of attribute "AXIdentifier" of window 1
                end tell
            end tell
        ' 2>/dev/null || echo "")
    fi

# ---------------------------------------------------------------------------
# QEMU path (Windows)
# ---------------------------------------------------------------------------

elif [[ "$_TOOL" == "qemu" ]]; then

    _GOLDEN_DIR="$HOME/.guivision/golden"
    _CLONE_DIR="$HOME/.guivision/clones/$_NAME"

    # Check golden QCOW2 exists, offer to create if missing
    _GOLDEN_QCOW2="$_GOLDEN_DIR/$_BASE.qcow2"
    if [[ ! -f "$_GOLDEN_QCOW2" ]]; then
        echo "Golden image '$_GOLDEN_QCOW2' not found."
        echo "Create it with: scripts/vm-create-golden-windows.sh"
        echo ""
        read -p "Create it now? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            scripts/vm-create-golden-windows.sh
        else
            exit 1
        fi
    fi

    # Remove existing clone if present
    if [[ -d "$_CLONE_DIR" ]]; then
        echo "Removing existing clone directory '$_CLONE_DIR'..."
        rm -rf "$_CLONE_DIR"
    fi

    mkdir -p "$_CLONE_DIR"

    # Clone disk image (copy-on-write overlay)
    echo "Cloning $_BASE → $_NAME..."
    _CLONE_QCOW2="$_CLONE_DIR/$_NAME.qcow2"
    qemu-img create -f qcow2 -b "$_GOLDEN_QCOW2" -F qcow2 "$_CLONE_QCOW2"

    # Copy UEFI vars and TPM state from golden
    cp "$_GOLDEN_DIR/$_BASE-efivars.fd" "$_CLONE_DIR/$_NAME-efivars.fd"
    cp -r "$_GOLDEN_DIR/$_BASE-tpm" "$_CLONE_DIR/$_NAME-tpm"

    _CLONE_EFIVARS="$_CLONE_DIR/$_NAME-efivars.fd"
    _CLONE_TPM_DIR="$_CLONE_DIR/$_NAME-tpm"
    _TPM_SOCKET="$_CLONE_TPM_DIR/swtpm-sock"

    # Locate UEFI code firmware
    _QEMU_PREFIX=$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")
    _UEFI_CODE="$_QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"
    if [[ ! -f "$_UEFI_CODE" ]]; then
        echo "ERROR: UEFI firmware not found at $_UEFI_CODE"
        rm -rf "$_CLONE_DIR"
        exit 1
    fi

    # Start swtpm
    echo "Starting swtpm..."
    swtpm socket \
        --tpmstate "dir=$_CLONE_TPM_DIR" \
        --ctrl "type=unixio,path=$_TPM_SOCKET" \
        --tpm2 \
        --log "level=0" \
        --daemon
    sleep 1

    # Boot QEMU
    echo "Booting QEMU VM..."
    qemu-system-aarch64 \
        -machine virt,highmem=on,gic-version=3 \
        -accel hvf \
        -cpu host \
        -m 4096 \
        -drive "if=pflash,format=raw,file=$_UEFI_CODE,readonly=on" \
        -drive "if=pflash,format=raw,file=$_CLONE_EFIVARS" \
        -chardev "socket,id=chrtpm,path=$_TPM_SOCKET" \
        -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
        -device "tpm-tis-sysbus,tpmdev=tpm0" \
        -drive "file=$_CLONE_QCOW2,if=none,id=hd0,format=qcow2" \
        -device "nvme,serial=guivision,drive=hd0" \
        -device "virtio-net-pci,netdev=net0" \
        -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
        -vnc ":1" \
        -display none &
    _QEMU_PID=$!
    echo "qemu PID: $_QEMU_PID"

    sleep 1
    if ! kill -0 "$_QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU does not appear to have started"
        rm -rf "$_CLONE_DIR"
        exit 1
    fi

    echo "VNC: localhost:5901"

    export GUIVISION_VNC="localhost:5901"
    unset GUIVISION_VNC_PASSWORD 2>/dev/null || true
    export GUIVISION_PLATFORM="$_PLATFORM"
    export GUIVISION_VM_TOOL="qemu"

    # Wait for SSH
    if $_SSH; then
        echo "Waiting for SSH at $_SSH_USER@localhost (port 2222)..."
        _SSH_READY=false
        for i in $(seq 1 80); do
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                   -o LogLevel=ERROR -o ConnectTimeout=5 \
                   -p 2222 "$_SSH_USER@localhost" "echo ok" &>/dev/null; then
                _SSH_READY=true
                break
            fi
            sleep 5
        done

        if $_SSH_READY; then
            export GUIVISION_SSH="$_SSH_USER@localhost -p 2222"
            echo "SSH: $_SSH_USER@localhost -p 2222"
        else
            echo "WARNING: SSH not reachable — SSH tests will be skipped"
        fi
    fi

    # Open VNC viewer (no password for QEMU default VNC)
    _WINDOW_ID=""
    if $_VIEWER; then
        echo "Opening VNC viewer..."
        open "vnc://localhost:5901"
        sleep 1
        _WINDOW_ID=$(osascript -e '
            tell application "System Events"
                tell process "Screen Sharing"
                    return value of attribute "AXIdentifier" of window 1
                end tell
            end tell
        ' 2>/dev/null || echo "")
    fi

fi

# --- Run Tests ---

echo ""
echo "Running integration tests..."
echo ""
swift test --filter "$_FILTER"
