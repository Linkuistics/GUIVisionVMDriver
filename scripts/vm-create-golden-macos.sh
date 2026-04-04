#!/bin/bash
# Create a golden macOS VM image with SSH key auth configured.
# Deletes any existing golden image with the same name first.
#
# Usage:
#   scripts/vm-create-golden-macos.sh [options]
#
# Options:
#   --version VERSION   macOS version: tahoe, sequoia, sonoma (default: tahoe)
#   --name NAME         Golden image name (default: guivision-golden-macos-VERSION)
#
# Prerequisites:
#   - tart installed (/opt/homebrew/bin/tart)
#   - SSH public key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# What this creates:
#   A tart VM cloned from Cirrus Labs' vanilla macOS image with:
#   - Host SSH public key in ~/.ssh/authorized_keys (key-based auth)
#   - Session restore disabled (Terminal won't reopen old windows)
#   - Clean desktop state
#
# The golden image is never run directly — clone from it for each test session.

set -eu

_VERSION="tahoe"
_NAME=""
_VANILLA_USER="admin"
_VANILLA_PASS="admin"
_SETUP_VM="guivision-setup-$$"
_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30"

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) _VERSION="$2"; shift 2 ;;
        --name)    _NAME="$2"; shift 2 ;;
        *)         echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$_NAME" ]]; then
    _NAME="guivision-golden-macos-$_VERSION"
fi

_VANILLA="ghcr.io/cirruslabs/macos-$_VERSION-vanilla:latest"

# --- Preflight ---

if ! command -v tart &>/dev/null; then
    echo "ERROR: tart not found. Install from https://tart.run"
    exit 1
fi

# Find SSH public key
_SSH_KEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$keyfile" ]]; then
        _SSH_KEY="$keyfile"
        break
    fi
done
if [[ -z "$_SSH_KEY" ]]; then
    echo "ERROR: No SSH public key found (~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)"
    echo "Generate one with: ssh-keygen -t ed25519"
    exit 1
fi
echo "Using SSH key: $_SSH_KEY"

# --- Cleanup on exit ---

cleanup() {
    # Clean up setup VM and askpass helper
    tart stop "$_SETUP_VM" 2>/dev/null || true
    tart delete "$_SETUP_VM" 2>/dev/null || true
    rm -f "$_ASKPASS_FILE" 2>/dev/null || true
    if [[ -n "${_TART_PID:-}" ]] && kill -0 "$_TART_PID" 2>/dev/null; then
        kill "$_TART_PID" 2>/dev/null
        wait "$_TART_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

# --- Delete existing golden if present ---

_VM_LIST=$(tart list --format json 2>/dev/null || echo "[]")
if echo "$_VM_LIST" | grep -q "\"$_NAME\""; then
    echo "Deleting existing golden image '$_NAME'..."
    tart stop "$_NAME" 2>/dev/null || true
    tart delete "$_NAME"
fi

# --- Pull and clone vanilla image ---

echo "Cloning $_VANILLA → $_SETUP_VM..."
echo "(This may pull the image on first run — can take several minutes)"
tart clone "$_VANILLA" "$_SETUP_VM"

# --- Boot the setup VM ---

echo "Booting setup VM..."
_VNC_OUTPUT=$(mktemp)
tart run "$_SETUP_VM" --no-graphics --vnc-experimental > "$_VNC_OUTPUT" 2>&1 &
_TART_PID=$!

# Wait for VNC (just to confirm it's booting)
for i in $(seq 1 60); do
    if grep -q 'vnc://' "$_VNC_OUTPUT" 2>/dev/null; then
        break
    fi
    sleep 1
done
rm -f "$_VNC_OUTPUT"

# --- Set up SSH_ASKPASS for password auth to vanilla image ---

_ASKPASS_FILE=$(mktemp)
cat > "$_ASKPASS_FILE" << EOF
#!/bin/bash
echo '$_VANILLA_PASS'
EOF
chmod 700 "$_ASKPASS_FILE"
export SSH_ASKPASS="$_ASKPASS_FILE"
export SSH_ASKPASS_REQUIRE="force"
export DISPLAY=:0

# --- Wait for SSH ---

echo -n "Waiting for SSH..."
_IP=""
_SSH_READY=false
for i in $(seq 1 60); do
    _IP=$(tart ip "$_SETUP_VM" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$_IP" ]]; then
        if ssh $_SSH_OPTS "$_VANILLA_USER@$_IP" "true" 2>/dev/null; then
            _SSH_READY=true
            echo " ready (IP: $_IP)"
            break
        fi
    fi
    echo -n "."
    sleep 3
done

if ! $_SSH_READY; then
    echo ""
    echo "ERROR: SSH not reachable within 180s"
    exit 1
fi

# --- Helper functions ---

vm_ssh() {
    ssh $_SSH_OPTS "$_VANILLA_USER@$_IP" "$1"
}

vm_scp() {
    scp $_SSH_OPTS "$1" "$_VANILLA_USER@$_IP:$2"
}

# --- Install SSH key ---

echo "Installing SSH key..."
vm_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
vm_scp "$_SSH_KEY" "/tmp/host_key.pub"
vm_ssh "cat /tmp/host_key.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && rm /tmp/host_key.pub"

# Verify key-based auth works without password
unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
if ssh $_SSH_OPTS "$_VANILLA_USER@$_IP" "echo ok" 2>/dev/null | grep -q "ok"; then
    echo "SSH key auth verified."
else
    echo "ERROR: SSH key auth failed — password auth still required"
    exit 1
fi

# --- Disable session restore ---

echo "Configuring macOS defaults..."
vm_ssh "defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false"
vm_ssh "defaults write com.apple.loginwindow TALLogoutSavesState -bool false"
vm_ssh "defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false"
vm_ssh "defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false"

# --- Set solid wallpaper ---
# A solid background makes visual processing of screenshots more reliable.
# We compile a tiny helper on the host (needs AppKit/NSWorkspace) and SCP
# it to the VM since the vanilla image has no dev tools yet.

echo "Setting wallpaper to solid gray..."
_HELPER_SRC="$(cd "$(dirname "$0")" && pwd)/helpers/set-wallpaper.swift"
_HELPER_BIN=$(mktemp)
if [[ -f "$_HELPER_SRC" ]] && swiftc -o "$_HELPER_BIN" "$_HELPER_SRC" 2>/dev/null; then
    # Create a 1x1 mid-gray (128,128,128) PNG and scale it with sips
    vm_ssh 'echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNoaGgAAAMEAYFL09IQAAAAAElFTkSuQmCC" | base64 -d > /tmp/solid.png && sips -z 1080 1920 /tmp/solid.png >/dev/null 2>&1 && mkdir -p ~/Pictures && mv /tmp/solid.png ~/Pictures/solid_gray.png'
    vm_scp "$_HELPER_BIN" "/tmp/set-wallpaper"
    vm_ssh "chmod +x /tmp/set-wallpaper && /tmp/set-wallpaper /Users/$_VANILLA_USER/Pictures/solid_gray.png && rm /tmp/set-wallpaper"
else
    echo "WARNING: Could not compile set-wallpaper helper — skipping wallpaper"
fi
rm -f "$_HELPER_BIN"

# --- Hide desktop widgets ---

echo "Hiding desktop widgets..."
vm_ssh "defaults write com.apple.WindowManager StandardHideWidgets -bool true"

# --- Install Xcode Command Line Tools ---

echo "Installing Xcode Command Line Tools (this takes a few minutes)..."
vm_ssh "touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
_CLT_LABEL=$(vm_ssh "softwareupdate -l 2>&1 | grep -B 1 'Command Line Tools' | grep '\\*' | head -1 | sed 's/^.*\\* Label: //'" || true)
if [[ -n "$_CLT_LABEL" ]]; then
    echo "  Found: $_CLT_LABEL"
    vm_ssh "softwareupdate --install '$_CLT_LABEL' --verbose 2>&1 | tail -1"
    vm_ssh "rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    if vm_ssh "xcode-select -p" &>/dev/null; then
        echo "  Xcode CLI tools installed."
    else
        echo "  WARNING: Xcode CLI tools installation may have failed"
    fi
else
    echo "  WARNING: Could not find Xcode CLI tools in software update — skipping"
    vm_ssh "rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
fi

# --- Install Homebrew ---

echo "Installing Homebrew..."
vm_ssh 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
vm_ssh 'echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile'
if vm_ssh "/opt/homebrew/bin/brew --version" &>/dev/null; then
    echo "  Homebrew installed."
else
    echo "  WARNING: Homebrew installation may have failed"
fi

# --- Close Terminal and clean desktop state ---

echo "Closing Terminal..."
vm_ssh "osascript -e 'tell application \"Terminal\" to quit' 2>/dev/null || true"
sleep 2
vm_ssh "rm -rf ~/Library/Saved\ Application\ State/*" 2>/dev/null || true

# --- Logout cycle ---
# A logout/login cycle is needed for loginwindow to pick up defaults changes
# (widget hiding, session restore, wallpaper). Without this, the settings
# are written but the running session still shows the old state.

echo -n "Logging out to apply settings..."
vm_ssh "sudo launchctl bootout gui/\$(id -u)" 2>/dev/null || true

# Wait for SSH to drop (logout) then come back (auto-login)
sleep 5
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=5 \
           "$_VANILLA_USER@$_IP" "true" &>/dev/null; then
        echo " logged back in."
        break
    fi
    echo -n "."
    sleep 3
done

# Give the desktop a moment to fully load after login
sleep 5

# --- Agent install and TCC/SIP functions ---

install_agent() {
    echo "Building guivision and guivision-agent..."
    local _BIN_PATH
    _BIN_PATH=$(swift build -c release --show-bin-path 2>/dev/null)
    swift build -c release

    _GUIVISION_BIN="$_BIN_PATH/guivision"
    local _AGENT_BIN="$_BIN_PATH/guivision-agent"
    if [[ ! -f "$_AGENT_BIN" ]]; then
        echo "ERROR: guivision-agent binary not found at $_AGENT_BIN"
        exit 1
    fi
    if [[ ! -f "$_GUIVISION_BIN" ]]; then
        echo "ERROR: guivision binary not found at $_GUIVISION_BIN"
        exit 1
    fi

    echo "Installing guivision-agent to VM..."
    vm_scp "$_AGENT_BIN" "/tmp/guivision-agent"
    vm_ssh "sudo mv /tmp/guivision-agent /usr/local/bin/guivision-agent"
    vm_ssh "sudo chmod +x /usr/local/bin/guivision-agent"

    echo "Verifying guivision-agent install..."
    if vm_ssh "/usr/local/bin/guivision-agent health" &>/dev/null; then
        echo "  guivision-agent installed and healthy."
    else
        echo "  WARNING: guivision-agent health check failed — binary may need runtime dependencies"
    fi
}

# Shared helper: gracefully stop the VM and wait for the tart process to exit.
_stop_vm_graceful() {
    echo -n "Shutting down VM..."
    vm_ssh "sudo shutdown -h now" 2>/dev/null || true
    for i in $(seq 1 60); do
        if ! kill -0 "$_TART_PID" 2>/dev/null; then
            echo " done."
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo " forcing stop."
    tart stop "$_SETUP_VM" 2>/dev/null || true
    wait "$_TART_PID" 2>/dev/null || true
}

# Shared helper: wait for SSH to become available after a reboot.
_wait_for_ssh_ready() {
    echo -n "Waiting for SSH..."
    for i in $(seq 1 60); do
        _IP=$(tart ip "$_SETUP_VM" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$_IP" ]]; then
            if ssh $_SSH_OPTS "$_VANILLA_USER@$_IP" "true" 2>/dev/null; then
                echo " ready (IP: $_IP)"
                return 0
            fi
        fi
        echo -n "."
        sleep 3
    done
    echo ""
    echo "ERROR: SSH not reachable within 180s after reboot"
    exit 1
}

# Shared helper: boot into recovery, run a csrutil command via VNC automation,
# then reboot normally. Uses guivision to drive the recovery Terminal over VNC.
#
# In macOS Recovery:
#   1. The VM boots to a recovery options screen
#   2. We use keyboard shortcuts to open Terminal (Cmd+Shift+T or via menu)
#   3. Type the csrutil command
#   4. Stop the VM and reboot normally
#
# Requires: $_GUIVISION_BIN set by install_agent()
_recovery_boot_csrutil() {
    local _CSRUTIL_CMD="$1"
    local _LABEL="$2"

    echo "=== SIP: ${_LABEL} via Recovery Mode ==="
    _stop_vm_graceful

    echo "Booting into Recovery Mode with VNC..."
    local _VNC_OUTPUT
    _VNC_OUTPUT=$(mktemp)
    tart run "$_SETUP_VM" --recovery --no-graphics --vnc-experimental > "$_VNC_OUTPUT" 2>&1 &
    _TART_PID=$!

    # Wait for VNC endpoint
    local _VNC_URL=""
    echo -n "Waiting for VNC..."
    for i in $(seq 1 60); do
        _VNC_URL=$(grep -o 'vnc://[^ ]*' "$_VNC_OUTPUT" 2>/dev/null || true)
        if [[ -n "$_VNC_URL" ]]; then
            echo " available ($_VNC_URL)"
            break
        fi
        echo -n "."
        sleep 1
    done
    rm -f "$_VNC_OUTPUT"

    if [[ -z "$_VNC_URL" ]]; then
        echo ""
        echo "ERROR: VNC not available for recovery boot"
        exit 1
    fi

    # Extract host:port from vnc://host:port
    local _VNC_ENDPOINT
    _VNC_ENDPOINT=$(echo "$_VNC_URL" | sed 's|vnc://||')

    # Recovery takes a while to reach the options screen.
    echo -n "Waiting for Recovery environment to load (60s)..."
    sleep 60
    echo " done."

    # Take a diagnostic screenshot to verify recovery booted
    "$_GUIVISION_BIN" screenshot --vnc "$_VNC_ENDPOINT" --output /tmp/guivision-recovery-pre.png 2>/dev/null || true
    echo "  Recovery screenshot saved to /tmp/guivision-recovery-pre.png"

    # Open Terminal in Recovery via the Utilities menu.
    # In macOS Recovery, the menu bar has: Apple, <app>, Utilities, Window, Help
    # We use Ctrl+F2 to focus the menu bar, then keyboard to navigate.
    echo "Opening Terminal in Recovery via menu bar..."

    # Focus menu bar with Ctrl+F2 (Fn+Ctrl+F2 on Apple keyboards)
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" f2 --modifiers ctrl
    sleep 1

    # Navigate to Utilities menu (press right arrow a few times to reach it)
    # Recovery app menu order: Apple (skip), Recovery app, Utilities
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" right
    sleep 0.3
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" right
    sleep 0.3
    # Open the Utilities menu
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" return
    sleep 0.5
    # Terminal is typically the first or second item in Utilities menu
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" down
    sleep 0.3
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" return
    sleep 3

    # Terminal should now be open. Type the csrutil command.
    echo "Running '${_CSRUTIL_CMD}' in recovery Terminal..."
    "$_GUIVISION_BIN" input type --vnc "$_VNC_ENDPOINT" "$_CSRUTIL_CMD"
    sleep 0.5
    "$_GUIVISION_BIN" input key --vnc "$_VNC_ENDPOINT" return
    sleep 3

    # Take a post-command screenshot for verification
    "$_GUIVISION_BIN" screenshot --vnc "$_VNC_ENDPOINT" --output /tmp/guivision-recovery-post.png 2>/dev/null || true
    echo "  Post-command screenshot saved to /tmp/guivision-recovery-post.png"

    echo "Stopping recovery boot..."
    tart stop "$_SETUP_VM" 2>/dev/null || true
    wait "$_TART_PID" 2>/dev/null || true

    echo "Rebooting normally after ${_LABEL}..."
    tart run "$_SETUP_VM" --no-graphics &
    _TART_PID=$!
    _wait_for_ssh_ready
}

recovery_boot_disable_sip() {
    _recovery_boot_csrutil "csrutil disable" "disabling SIP"
}

recovery_boot_enable_sip() {
    _recovery_boot_csrutil "csrutil enable" "re-enabling SIP"
}

# Write the guivision-agent accessibility grant directly into the system-level
# TCC database.  SIP MUST be disabled before this sqlite3 write will succeed —
# call this function between recovery_boot_disable_sip and recovery_boot_enable_sip.
grant_accessibility_permission() {
    echo "Granting accessibility permission to guivision-agent..."

    vm_ssh "sudo sqlite3 \"/Library/Application Support/com.apple.TCC/TCC.db\" \
        \"INSERT OR REPLACE INTO access \
          (service, client, client_type, auth_value, auth_reason, auth_version, \
           indirect_object_identifier_type, indirect_object_identifier, flags, last_modified) \
        VALUES \
          ('kTCCServiceAccessibility', '/usr/local/bin/guivision-agent', 1, 2, 0, 1, \
           0, 'UNUSED', 0, strftime('%s','now'));\""

    local _RESULT
    _RESULT=$(vm_ssh "sudo sqlite3 \"/Library/Application Support/com.apple.TCC/TCC.db\" \
        \"SELECT client FROM access WHERE service='kTCCServiceAccessibility' \
          AND client='/usr/local/bin/guivision-agent';\"" 2>/dev/null || true)
    if echo "$_RESULT" | grep -q "guivision-agent"; then
        echo "  Accessibility permission granted."
    else
        echo "  ERROR: TCC insert verification failed — SIP may still be enabled or sqlite3 unavailable"
        exit 1
    fi
}

# --- Run agent installation and TCC/SIP cycle ---

install_agent
recovery_boot_disable_sip
grant_accessibility_permission
recovery_boot_enable_sip

echo "Final agent health check..."
if vm_ssh "/usr/local/bin/guivision-agent health" &>/dev/null; then
    echo "  guivision-agent healthy."
else
    echo "  WARNING: guivision-agent health check failed after TCC/SIP cycle"
fi

# --- Shutdown ---

echo "Shutting down VM..."
vm_ssh "sudo shutdown -h now" 2>/dev/null || true

echo -n "Waiting for shutdown..."
for i in $(seq 1 60); do
    if ! kill -0 "$_TART_PID" 2>/dev/null; then
        echo " done."
        break
    fi
    echo -n "."
    sleep 2
done
if kill -0 "$_TART_PID" 2>/dev/null; then
    echo " forcing stop."
    tart stop "$_SETUP_VM" 2>/dev/null || true
    wait "$_TART_PID" 2>/dev/null || true
fi

# --- Clone to golden ---

echo "Creating golden image '$_NAME'..."
tart clone "$_SETUP_VM" "$_NAME"
tart delete "$_SETUP_VM"

# Prevent cleanup trap from deleting the golden
_SETUP_VM="__already_deleted__"

echo ""
echo "Golden image '$_NAME' created successfully."
echo ""
echo "Use it with:"
echo "  scripts/test-integration.sh --base $_NAME"
echo "  source scripts/vm-start.sh --base $_NAME"
