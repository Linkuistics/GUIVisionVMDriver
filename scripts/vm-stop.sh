#!/bin/bash
# Stop the VM started by vm-start.sh and clean up env vars.
# Supports both tart (macOS) and QEMU VMs, selected via GUIVISION_VM_TOOL.
#
# Usage:
#   source scripts/vm-stop.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed."
    echo "  source scripts/vm-stop.sh"
    exit 1
fi

_NAME="${GUIVISION_VM_NAME:-guivision-inttest}"
_PID="${GUIVISION_VM_PID:-}"
_TOOL="${GUIVISION_VM_TOOL:-tart}"
_CLONE_DIR="${GUIVISION_VM_CLONE_DIR:-}"
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
echo "Stopping VM '$_NAME'..."

if [[ "$_TOOL" == "qemu" ]]; then
    # Kill the QEMU process
    if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
        kill "$_PID" 2>/dev/null
        wait "$_PID" 2>/dev/null || true
    fi

    # Kill the associated swtpm process (matched by TPM socket path in clone dir)
    if [[ -n "$_CLONE_DIR" ]]; then
        _TPM_SOCK="${_CLONE_DIR}/tpm/sock"
        _SWTPM_PID="$(pgrep -f "swtpm.*${_TPM_SOCK}" 2>/dev/null || true)"
        if [[ -n "$_SWTPM_PID" ]]; then
            kill "$_SWTPM_PID" 2>/dev/null || true
            # Give swtpm a moment to exit cleanly
            for _i in 1 2 3 4 5; do
                kill -0 "$_SWTPM_PID" 2>/dev/null || break
                sleep 0.2
            done
            kill -9 "$_SWTPM_PID" 2>/dev/null || true
        fi

        # Remove the clone directory (QCOW2, UEFI vars, TPM state)
        if [[ -d "$_CLONE_DIR" ]]; then
            rm -rf "$_CLONE_DIR"
        fi
    fi
else
    # tart (default)
    tart stop "$_NAME" 2>/dev/null || true
    tart delete "$_NAME" 2>/dev/null || true

    if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
        kill "$_PID" 2>/dev/null
        wait "$_PID" 2>/dev/null || true
    fi
fi

unset GUIVISION_VNC
unset GUIVISION_VNC_PASSWORD
unset GUIVISION_SSH
unset GUIVISION_PLATFORM
unset GUIVISION_VM_NAME
unset GUIVISION_VM_PID
unset GUIVISION_VM_TOOL
unset GUIVISION_VM_CLONE_DIR
unset GUIVISION_VM_VIEWER_WINDOW_ID

echo "VM '$_NAME' stopped and deleted. Environment cleaned."
