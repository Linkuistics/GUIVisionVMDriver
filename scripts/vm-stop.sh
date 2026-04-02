#!/bin/bash
# Stop the VM started by vm-start.sh and clean up env vars.
#
# Usage:
#   source scripts/vm-stop.sh

_NAME="${GUIVISION_VM_NAME:-guivision-inttest}"
_PID="${GUIVISION_VM_PID:-}"
_WINDOW_ID="${GUIVISION_VM_VIEWER_WINDOW_ID:-}"

# Close our specific VNC viewer window BEFORE stopping the VM.
# We match by AXIdentifier recorded at start time, so other
# Screen Sharing sessions are untouched.
if [[ -n "$_WINDOW_ID" ]] && pgrep -q "Screen Sharing"; then
    echo "Closing VNC viewer window..."
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

# Stop and delete the VM
if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
    echo "Stopping VM '$_NAME'..."
fi

tart stop "$_NAME" 2>/dev/null || true
tart delete "$_NAME" 2>/dev/null || true

if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
    kill "$_PID" 2>/dev/null
    wait "$_PID" 2>/dev/null
fi

unset GUIVISION_TEST_VNC
unset GUIVISION_TEST_VNC_PASSWORD
unset GUIVISION_TEST_SSH
unset GUIVISION_TEST_PLATFORM
unset GUIVISION_VM_NAME
unset GUIVISION_VM_PID
unset GUIVISION_VM_VIEWER_WINDOW_ID

echo "VM '$_NAME' stopped and deleted. Environment cleaned."
