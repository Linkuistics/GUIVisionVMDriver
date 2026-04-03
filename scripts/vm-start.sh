#!/bin/bash
# Start a VM (tart or QEMU) and export GUIVISION_* env vars for integration tests.
#
# Usage:
#   source scripts/vm-start.sh [options]
#
# Options:
#   --platform PLATFORM  Target platform: macos|linux|windows (default: macos)
#   --base IMAGE         Base image to clone from (default: platform-specific)
#   --name NAME          VM name / clone identifier (default: guivision-inttest)
#   --viewer             Open VNC viewer after boot
#   --no-ssh             Skip waiting for SSH
#
# Platform defaults for --base:
#   macos   → guivision-golden-macos-tahoe
#   linux   → guivision-golden-linux-24.04
#   windows → guivision-golden-windows-11
#
# After sourcing, these env vars are set:
#   GUIVISION_VNC=host:port
#   GUIVISION_VNC_PASSWORD=...           (tart only; unset for QEMU)
#   GUIVISION_SSH=admin@ip               (unless --no-ssh; QEMU: admin@localhost -p 2222)
#   GUIVISION_PLATFORM=macos|linux|windows
#   GUIVISION_VM_NAME=...                (for vm-stop.sh)
#   GUIVISION_VM_PID=...                 (tart or qemu-system-aarch64 PID)
#   GUIVISION_VM_TOOL=tart|qemu
#   GUIVISION_VM_CLONE_DIR=...           (QEMU only: ~/.guivision/clones/$_NAME/)
#
# QEMU clone files are stored in ~/.guivision/clones/$_NAME/ and the path is
# exported as GUIVISION_VM_CLONE_DIR so vm-stop.sh knows where to clean up.
# VNC is fixed at localhost:5901 and SSH is forwarded on localhost:2222 for QEMU.
#
# Then run tests:
#   swift test --filter IntegrationTests
#
# Clean up:
#   source scripts/vm-stop.sh

# Detect if run as subprocess instead of sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed."
    echo "  source scripts/vm-start.sh $*"
    exit 1
fi

set -euo pipefail

# Defaults
_PLATFORM="macos"
_BASE=""
_NAME="guivision-inttest"
_VIEWER=false
_SSH=true
_SSH_USER="admin"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) _PLATFORM="$2"; shift 2 ;;
        --base)     _BASE="$2"; shift 2 ;;
        --name)     _NAME="$2"; shift 2 ;;
        --viewer)   _VIEWER=true; shift ;;
        --no-ssh)   _SSH=false; shift ;;
        *)          echo "Unknown option: $1"; return 1 2>/dev/null || exit 1 ;;
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
        return 1 2>/dev/null || exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Tart path (macOS / Linux)
# ---------------------------------------------------------------------------

if [[ "$_TOOL" == "tart" ]]; then

    # Stop existing VM if running
    if tart list --format json 2>/dev/null | grep -q "\"$_NAME\""; then
        echo "Stopping existing VM '$_NAME'..."
        tart stop "$_NAME" 2>/dev/null || true
        sleep 2
        tart delete "$_NAME" 2>/dev/null || true
    fi

    # Clone
    echo "Cloning $_BASE → $_NAME..."
    tart clone "$_BASE" "$_NAME"

    # Start in background, capture output for VNC URL
    _VNC_OUTPUT=$(mktemp)
    tart run "$_NAME" --no-graphics --vnc-experimental > "$_VNC_OUTPUT" 2>&1 &
    _PID=$!
    echo "tart PID: $_PID"

    # Poll for VNC URL
    echo "Waiting for VNC..."
    _VNC_URL=""
    for i in $(seq 1 60); do
        _VNC_URL=$(grep -o 'vnc://[^ ]*' "$_VNC_OUTPUT" 2>/dev/null | head -1 | sed 's/\.\.\.$//')
        if [[ -n "$_VNC_URL" ]]; then
            break
        fi
        sleep 1
    done
    rm -f "$_VNC_OUTPUT"

    if [[ -z "$_VNC_URL" ]]; then
        echo "ERROR: VM did not produce a VNC URL within 60s"
        kill "$_PID" 2>/dev/null
        return 1 2>/dev/null || exit 1
    fi

    # Parse VNC URL components
    _VNC_HOST=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\3|')
    _VNC_PORT=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?([^:]+):([0-9]+)|\4|')
    _VNC_PASS=$(echo "$_VNC_URL" | sed -E 's|vnc://(:([^@]*)@)?.*|\2|')

    echo "VNC: $_VNC_HOST:$_VNC_PORT"

    # Export env vars
    export GUIVISION_VNC="$_VNC_HOST:$_VNC_PORT"
    export GUIVISION_VNC_PASSWORD="$_VNC_PASS"
    export GUIVISION_PLATFORM="$_PLATFORM"
    export GUIVISION_VM_NAME="$_NAME"
    export GUIVISION_VM_PID="$_PID"
    export GUIVISION_VM_TOOL="tart"

    # Wait for SSH if requested
    if $_SSH; then
        echo "Waiting for VM IP..."
        _IP=""
        for i in $(seq 1 30); do
            _IP=$(tart ip "$_NAME" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$_IP" ]]; then
                break
            fi
            sleep 2
        done

        if [[ -z "$_IP" ]]; then
            echo "WARNING: Could not get VM IP — SSH tests will be skipped"
        else
            echo "Waiting for SSH at $_SSH_USER@$_IP..."
            _SSH_READY=false
            for i in $(seq 1 40); do
                if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                       -o LogLevel=ERROR -o ConnectTimeout=5 \
                       "$_SSH_USER@$_IP" "echo ok" &>/dev/null; then
                    _SSH_READY=true
                    break
                fi
                sleep 3
            done

            if $_SSH_READY; then
                export GUIVISION_SSH="$_SSH_USER@$_IP"
                echo "SSH: $_SSH_USER@$_IP"
            else
                echo "WARNING: SSH not reachable — SSH tests will be skipped"
            fi
        fi
    fi

    # Open VNC viewer if requested
    if $_VIEWER; then
        echo "Opening VNC viewer..."
        open "$_VNC_URL"

        # Auto-type the VNC password via AppleScript
        if [[ -n "$_VNC_PASS" ]]; then
            sleep 2
            osascript -e "
                tell application \"System Events\"
                    keystroke \"$_VNC_PASS\"
                    keystroke return
                end tell
            " 2>/dev/null || echo "(Could not auto-type VNC password)"
        fi

        # Record the AXIdentifier of the new window so vm-stop.sh can close
        # exactly this window without affecting other Screen Sharing sessions.
        sleep 1
        _WINDOW_ID=$(osascript -e '
            tell application "System Events"
                tell process "Screen Sharing"
                    return value of attribute "AXIdentifier" of window 1
                end tell
            end tell
        ' 2>/dev/null || echo "")
        if [[ -n "$_WINDOW_ID" ]]; then
            export GUIVISION_VM_VIEWER_WINDOW_ID="$_WINDOW_ID"
        fi
    fi

# ---------------------------------------------------------------------------
# QEMU path (Windows)
# ---------------------------------------------------------------------------

elif [[ "$_TOOL" == "qemu" ]]; then

    _GOLDEN_DIR="$HOME/.guivision/golden"
    _CLONE_DIR="$HOME/.guivision/clones/$_NAME"

    # Stop / clean up existing clone if present
    if [[ -d "$_CLONE_DIR" ]]; then
        echo "Removing existing clone directory '$_CLONE_DIR'..."
        rm -rf "$_CLONE_DIR"
    fi

    # Create clone directory
    mkdir -p "$_CLONE_DIR"

    # Clone disk image (copy-on-write overlay backed by the golden qcow2)
    echo "Cloning $_BASE → $_NAME..."
    _GOLDEN_QCOW2="$_GOLDEN_DIR/$_BASE.qcow2"
    _CLONE_QCOW2="$_CLONE_DIR/$_NAME.qcow2"
    qemu-img create -f qcow2 -b "$_GOLDEN_QCOW2" -F qcow2 "$_CLONE_QCOW2"

    # Copy UEFI vars and TPM state from golden
    cp "$_GOLDEN_DIR/$_BASE-efivars.fd" "$_CLONE_DIR/$_NAME-efivars.fd"
    cp -r "$_GOLDEN_DIR/$_BASE-tpm" "$_CLONE_DIR/$_NAME-tpm"

    _CLONE_EFIVARS="$_CLONE_DIR/$_NAME-efivars.fd"
    _CLONE_TPM_DIR="$_CLONE_DIR/$_NAME-tpm"
    _TPM_SOCKET="$_CLONE_TPM_DIR/swtpm-sock"

    # Locate UEFI code firmware (read-only, from QEMU installation)
    _QEMU_PREFIX=$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")
    _UEFI_CODE="$_QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"
    if [[ ! -f "$_UEFI_CODE" ]]; then
        echo "ERROR: UEFI firmware not found at $_UEFI_CODE"
        rm -rf "$_CLONE_DIR"
        return 1 2>/dev/null || exit 1
    fi

    # Start swtpm for the clone's TPM state
    echo "Starting swtpm..."
    swtpm socket \
        --tpmstate "dir=$_CLONE_TPM_DIR" \
        --ctrl "type=unixio,path=$_TPM_SOCKET" \
        --tpm2 \
        --log "level=0" \
        --daemon
    sleep 1

    # Boot with QEMU
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
        -drive "file=$_CLONE_QCOW2,if=virtio,format=qcow2" \
        -nic "user,model=virtio-net-pci,hostfwd=tcp::2222-:22" \
        -vnc ":1" \
        -display none &
    _PID=$!
    echo "qemu PID: $_PID"

    sleep 1
    if ! kill -0 "$_PID" 2>/dev/null; then
        echo "ERROR: QEMU does not appear to have started"
        rm -rf "$_CLONE_DIR"
        return 1 2>/dev/null || exit 1
    fi

    # VNC and SSH are known at launch — no discovery needed
    echo "VNC: localhost:5901"

    # Export env vars
    export GUIVISION_VNC="localhost:5901"
    unset GUIVISION_VNC_PASSWORD 2>/dev/null || true
    export GUIVISION_PLATFORM="$_PLATFORM"
    export GUIVISION_VM_NAME="$_NAME"
    export GUIVISION_VM_PID="$_PID"
    export GUIVISION_VM_TOOL="qemu"
    export GUIVISION_VM_CLONE_DIR="$_CLONE_DIR"

    # Wait for SSH if requested
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

    # Open VNC viewer if requested (no password for QEMU default VNC)
    if $_VIEWER; then
        echo "Opening VNC viewer..."
        open "vnc://localhost:5901"

        # Record the AXIdentifier of the new window so vm-stop.sh can close
        # exactly this window without affecting other Screen Sharing sessions.
        sleep 1
        _WINDOW_ID=$(osascript -e '
            tell application "System Events"
                tell process "Screen Sharing"
                    return value of attribute "AXIdentifier" of window 1
                end tell
            end tell
        ' 2>/dev/null || echo "")
        if [[ -n "$_WINDOW_ID" ]]; then
            export GUIVISION_VM_VIEWER_WINDOW_ID="$_WINDOW_ID"
        fi
    fi

fi

echo ""
echo "VM ready. Environment variables set:"
echo "  GUIVISION_VNC=$GUIVISION_VNC"
[[ -n "${GUIVISION_VNC_PASSWORD:-}" ]] && echo "  GUIVISION_VNC_PASSWORD=(set)"
[[ -n "${GUIVISION_SSH:-}" ]] && echo "  GUIVISION_SSH=$GUIVISION_SSH"
echo "  GUIVISION_PLATFORM=$GUIVISION_PLATFORM"
echo "  GUIVISION_VM_TOOL=$GUIVISION_VM_TOOL"
[[ -n "${GUIVISION_VM_CLONE_DIR:-}" ]] && echo "  GUIVISION_VM_CLONE_DIR=$GUIVISION_VM_CLONE_DIR"
echo ""
echo "Run tests:  swift test --filter IntegrationTests"
echo "Stop VM:    source scripts/vm-stop.sh"
