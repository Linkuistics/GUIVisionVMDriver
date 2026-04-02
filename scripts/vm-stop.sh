#!/bin/bash
# Stop the VM started by vm-start.sh and clean up env vars.
#
# Usage:
#   source scripts/vm-stop.sh

_NAME="${GUIVISION_VM_NAME:-guivision-inttest}"
_PID="${GUIVISION_VM_PID:-}"

# Close VNC viewer (Screen Sharing.app)
osascript -e 'tell application "Screen Sharing" to quit' 2>/dev/null || true
# If osascript fails (e.g. app is hung on a dead connection), force kill
sleep 0.5
killall "Screen Sharing" 2>/dev/null || true

if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
    echo "Stopping tart (PID $_PID)..."
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

echo "VM '$_NAME' stopped and deleted. Environment cleaned."
