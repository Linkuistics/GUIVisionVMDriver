#!/bin/bash
# Run integration tests against a tart VM.
# Starts the VM if needed, runs tests, stops the VM.
#
# Usage:
#   scripts/test-integration.sh [options]
#
# Options:
#   --base IMAGE    Base image to clone from (default: testanyware-golden-tahoe)
#   --name NAME     VM name (default: guivision-inttest)
#   --viewer        Open VNC viewer to watch tests run
#   --no-ssh        Skip SSH tests
#   --keep          Don't stop the VM after tests (for debugging)
#   --filter EXPR   Swift test filter (default: IntegrationTests)

set -eu
cd "$(dirname "$0")/.."

_BASE="testanyware-golden-tahoe"
_NAME="guivision-inttest"
_VIEWER=false
_SSH=true
_SSH_USER="admin"
_KEEP=false
_FILTER="IntegrationTests"

while [[ $# -gt 0 ]]; do
    case $1 in
        --base)   _BASE="$2"; shift 2 ;;
        --name)   _NAME="$2"; shift 2 ;;
        --viewer) _VIEWER=true; shift ;;
        --no-ssh) _SSH=false; shift ;;
        --keep)   _KEEP=true; shift ;;
        --filter) _FILTER="$2"; shift 2 ;;
        *)        echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- VM Lifecycle ---

cleanup() {
    if $_KEEP; then
        echo ""
        echo "VM '$_NAME' kept running (--keep). To stop:"
        echo "  tart stop $_NAME && tart delete $_NAME"
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

    echo "Stopping VM '$_NAME'..."
    tart stop "$_NAME" 2>/dev/null || true
    tart delete "$_NAME" 2>/dev/null || true
    if [[ -n "${_TART_PID:-}" ]] && kill -0 "$_TART_PID" 2>/dev/null; then
        kill "$_TART_PID" 2>/dev/null
        wait "$_TART_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

# Check base image exists
_VM_LIST=$(tart list --format json 2>/dev/null || echo "[]")
if ! echo "$_VM_LIST" | grep -q "\"$_BASE\""; then
    echo "ERROR: Base image '$_BASE' not found."
    echo "Available images:"
    echo "$_VM_LIST" | python3 -c "
import sys, json
for vm in json.load(sys.stdin):
    print(f'  {vm[\"Name\"]}  ({vm[\"State\"]})')
" 2>/dev/null || tart list 2>/dev/null
    exit 1
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

export GUIVISION_TEST_VNC="$_VNC_HOST:$_VNC_PORT"
export GUIVISION_TEST_VNC_PASSWORD="$_VNC_PASS"
export GUIVISION_TEST_PLATFORM="macos"

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
                export GUIVISION_TEST_SSH="$_SSH_USER@$_IP"
                echo "SSH: $_SSH_USER@$_IP"
                break
            fi
            sleep 3
        done
    fi

    if [[ -z "${GUIVISION_TEST_SSH:-}" ]]; then
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

# --- Run Tests ---

echo ""
echo "Running integration tests..."
echo ""
swift test --filter "$_FILTER"
