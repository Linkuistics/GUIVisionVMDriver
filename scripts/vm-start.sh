#!/bin/bash
# Start a tart VM and export GUIVISION_TEST_* env vars for integration tests.
#
# Usage:
#   source scripts/vm-start.sh [options]
#
# Options:
#   --base IMAGE    Base image to clone from (default: testanyware-golden-tahoe)
#   --name NAME     VM name (default: guivision-inttest)
#   --viewer        Open VNC viewer after boot
#   --no-ssh        Skip waiting for SSH
#
# After sourcing, these env vars are set:
#   GUIVISION_TEST_VNC=host:port
#   GUIVISION_TEST_VNC_PASSWORD=...
#   GUIVISION_TEST_SSH=admin@ip          (unless --no-ssh)
#   GUIVISION_TEST_PLATFORM=macos
#   GUIVISION_VM_NAME=...                (for vm-stop.sh)
#   GUIVISION_VM_PID=...                 (tart process PID)
#
# Then run tests:
#   swift test --filter IntegrationTests
#
# Clean up:
#   source scripts/vm-stop.sh

set -euo pipefail

# Defaults
_BASE="testanyware-golden-tahoe"
_NAME="guivision-inttest"
_VIEWER=false
_SSH=true
_SSH_USER="admin"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --base)   _BASE="$2"; shift 2 ;;
        --name)   _NAME="$2"; shift 2 ;;
        --viewer) _VIEWER=true; shift ;;
        --no-ssh) _SSH=false; shift ;;
        *)        echo "Unknown option: $1"; return 1 2>/dev/null || exit 1 ;;
    esac
done

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

# Export VNC env vars
export GUIVISION_TEST_VNC="$_VNC_HOST:$_VNC_PORT"
export GUIVISION_TEST_VNC_PASSWORD="$_VNC_PASS"
export GUIVISION_TEST_PLATFORM="macos"
export GUIVISION_VM_NAME="$_NAME"
export GUIVISION_VM_PID="$_PID"

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
            export GUIVISION_TEST_SSH="$_SSH_USER@$_IP"
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

    # Auto-type the VNC password via AppleScript (like TestAnyware does)
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

echo ""
echo "VM ready. Environment variables set:"
echo "  GUIVISION_TEST_VNC=$GUIVISION_TEST_VNC"
[[ -n "${GUIVISION_TEST_VNC_PASSWORD:-}" ]] && echo "  GUIVISION_TEST_VNC_PASSWORD=(set)"
[[ -n "${GUIVISION_TEST_SSH:-}" ]] && echo "  GUIVISION_TEST_SSH=$GUIVISION_TEST_SSH"
echo "  GUIVISION_TEST_PLATFORM=$GUIVISION_TEST_PLATFORM"
echo ""
echo "Run tests:  swift test --filter IntegrationTests"
echo "Stop VM:    source scripts/vm-stop.sh"
