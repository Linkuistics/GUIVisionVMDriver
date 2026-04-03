#!/bin/bash
# Create a golden Linux VM image with SSH key auth configured.
# Deletes any existing golden image with the same name first.
#
# Usage:
#   scripts/vm-create-golden-linux.sh [options]
#
# Options:
#   --version VERSION   Ubuntu version codename (default: noble)
#   --name NAME         Golden image name (default: guivision-golden-linux-VERSION)
#
# Prerequisites:
#   - tart installed (/opt/homebrew/bin/tart)
#   - SSH public key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# What this creates:
#   A tart VM cloned from Cirrus Labs' vanilla Ubuntu image with:
#   - Host SSH public key in ~/.ssh/authorized_keys (key-based auth)
#   - Ubuntu Desktop (minimal) installed
#   - GDM autologin configured for the admin user
#   - Solid gray desktop background, screen lock and blanking disabled
#
# The golden image is never run directly — clone from it for each test session.

set -eu

_VERSION="noble"
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
    _NAME="guivision-golden-linux-$_VERSION"
fi

_VANILLA="ghcr.io/cirruslabs/ubuntu:$_VERSION"

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
tart run "$_SETUP_VM" --no-graphics &
_TART_PID=$!

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

# --- Install Ubuntu Desktop ---

echo "Installing Ubuntu Desktop (this takes several minutes)..."
vm_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get update -q"
vm_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal"
echo "  Ubuntu Desktop installed."

# --- Configure GDM autologin ---

echo "Configuring autologin..."
vm_ssh "sudo tee /etc/gdm3/custom.conf > /dev/null << 'GDMCONF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=admin
GDMCONF"

# --- Set solid wallpaper and disable desktop clutter ---

echo "Configuring desktop settings..."
vm_ssh "sudo tee /usr/share/glib-2.0/schemas/99-guivision.gschema.override > /dev/null << 'SCHEMA'
[org.gnome.desktop.background]
picture-options='none'
primary-color='#808080'

[org.gnome.desktop.screensaver]
lock-enabled=false

[org.gnome.desktop.session]
idle-delay=uint32 0

[org.gnome.desktop.notifications]
show-banners=false
SCHEMA"
vm_ssh "sudo glib-compile-schemas /usr/share/glib-2.0/schemas/"

# --- Reboot to apply all changes ---
# A reboot is required for GDM autologin and desktop settings to take full effect.

echo -n "Rebooting to apply settings..."
vm_ssh "sudo reboot" 2>/dev/null || true

# Wait for SSH to drop (reboot) then come back (autologin)
sleep 10
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=5 \
           "$_VANILLA_USER@$_IP" "true" &>/dev/null; then
        echo " back online."
        break
    fi
    echo -n "."
    sleep 3
done

if ! ssh $_SSH_OPTS "$_VANILLA_USER@$_IP" "true" &>/dev/null; then
    echo ""
    echo "ERROR: VM did not come back online after reboot"
    exit 1
fi

# Give the desktop a moment to fully load after login
sleep 5

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
