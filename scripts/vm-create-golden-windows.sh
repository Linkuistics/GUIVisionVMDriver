#!/bin/bash
# Create a golden Windows 11 ARM VM image with SSH key auth configured.
# Uses QEMU (not tart) since tart does not support Windows guests.
# Deletes any existing golden image with the same name first.
#
# Usage:
#   scripts/vm-create-golden-windows.sh [options]
#
# Options:
#   --version VERSION   Windows version (default: 11)
#   --name NAME         Golden image name (default: guivision-golden-windows-VERSION)
#
# Prerequisites:
#   - qemu-system-aarch64 installed (brew install qemu)
#   - qemu-img installed (comes with qemu)
#   - swtpm installed (brew install swtpm)
#   - SSH public key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# What this creates:
#   A QEMU VM built from a Microsoft evaluation VHDX with:
#   - Local 'admin' account with SSH key auth
#   - Autologin configured for 'admin'
#   - OpenSSH Server installed and running
#   - Solid gray desktop background
#   - Desktop clutter disabled (widgets, notifications, Cortana, etc.)
#
# Golden image files stored in ~/.guivision/golden/:
#   {name}.qcow2          — disk image
#   {name}-efivars.fd     — UEFI variables
#   {name}-tpm/           — TPM state directory
#
# The golden image is never run directly — use qemu-img create -b for COW clones.

set -eu

_VERSION="11"
_NAME=""
# NOTE: The initial user in the Windows evaluation image is uncertain.
# It may be "User", "IEUser", or something else. Update this after first run.
_INITIAL_USER="User"
_WIN_USER="$_INITIAL_USER"
_ADMIN_PASS="admin"
_SETUP_PREFIX="guivision-setup-$$"
_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30"
_SSH_PORT=2222
_VNC_DISPLAY=1
_QEMU_PID=""
_SWTPM_PID=""
_ASKPASS_FILE=""
_GOLDEN_DONE=false

_GOLDEN_DIR="$HOME/.guivision/golden"
_CACHE_DIR="$HOME/.guivision/cache"

# IMPORTANT: This URL is a placeholder. The actual download URL for the
# Windows 11 ARM64 evaluation VHDX changes periodically. To find the current URL:
#   1. Visit https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise
#   2. Select "Windows 11 Enterprise" and "ARM64"
#   3. Copy the download link for the VHDX format
# The evaluation image is valid for 90 days from first boot.
_VHDX_URL="https://TODO-UPDATE-WITH-ACTUAL-MICROSOFT-DOWNLOAD-URL"

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) _VERSION="$2"; shift 2 ;;
        --name)    _NAME="$2"; shift 2 ;;
        *)         echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$_NAME" ]]; then
    _NAME="guivision-golden-windows-$_VERSION"
fi

_SETUP_QCOW2="$_CACHE_DIR/${_SETUP_PREFIX}.qcow2"
_SETUP_EFIVARS="$_CACHE_DIR/${_SETUP_PREFIX}-efivars.fd"
_SETUP_TPM_DIR="$_CACHE_DIR/${_SETUP_PREFIX}-tpm"

# --- Preflight ---

echo "Creating golden Windows $_VERSION image: $_NAME"
echo ""

if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "ERROR: qemu-system-aarch64 not found. Install with: brew install qemu"
    exit 1
fi

if ! command -v qemu-img &>/dev/null; then
    echo "ERROR: qemu-img not found. Install with: brew install qemu"
    exit 1
fi

if ! command -v swtpm &>/dev/null; then
    echo "ERROR: swtpm not found. Install with: brew install swtpm"
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

# Create storage directories
mkdir -p "$_GOLDEN_DIR" "$_CACHE_DIR"

# --- Cleanup on exit ---

cleanup() {
    if [[ -n "${_QEMU_PID:-}" ]] && kill -0 "$_QEMU_PID" 2>/dev/null; then
        echo "Cleaning up: stopping QEMU..."
        kill "$_QEMU_PID" 2>/dev/null || true
        wait "$_QEMU_PID" 2>/dev/null || true
    fi
    if [[ -n "${_SWTPM_PID:-}" ]] && kill -0 "$_SWTPM_PID" 2>/dev/null; then
        echo "Cleaning up: stopping swtpm..."
        kill "$_SWTPM_PID" 2>/dev/null || true
        wait "$_SWTPM_PID" 2>/dev/null || true
    fi
    rm -f "$_ASKPASS_FILE" 2>/dev/null || true
    # Clean up setup files only if golden was not finalized
    if ! $_GOLDEN_DONE; then
        rm -f "$_SETUP_QCOW2" 2>/dev/null || true
        rm -f "$_SETUP_EFIVARS" 2>/dev/null || true
        rm -rf "$_SETUP_TPM_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- Delete existing golden if present ---

if [[ -f "$_GOLDEN_DIR/$_NAME.qcow2" ]]; then
    echo "Deleting existing golden image '$_NAME'..."
    rm -f "$_GOLDEN_DIR/$_NAME.qcow2"
    rm -f "$_GOLDEN_DIR/$_NAME-efivars.fd"
    rm -rf "$_GOLDEN_DIR/$_NAME-tpm"
fi

# --- Download and convert evaluation VHDX ---

_CACHED_VHDX="$_CACHE_DIR/windows-${_VERSION}-arm64-eval.vhdx"
_CACHED_QCOW2="$_CACHE_DIR/windows-${_VERSION}-arm64-eval.qcow2"

if [[ -f "$_CACHED_QCOW2" ]]; then
    echo "Using cached qcow2: $_CACHED_QCOW2"
else
    if [[ -f "$_CACHED_VHDX" ]]; then
        echo "Using cached VHDX: $_CACHED_VHDX"
    else
        echo "Downloading Windows $_VERSION ARM64 evaluation VHDX..."
        echo "  URL: $_VHDX_URL"
        if [[ "$_VHDX_URL" == *"TODO"* ]]; then
            echo ""
            echo "ERROR: The VHDX download URL is a placeholder."
            echo "Please update _VHDX_URL in this script with the actual Microsoft download URL."
            echo "Visit: https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise"
            exit 1
        fi
        curl -L -o "$_CACHED_VHDX" "$_VHDX_URL"
        echo "  Download complete."
    fi

    echo "Converting VHDX to qcow2 (this may take a few minutes)..."
    qemu-img convert -f vhdx -O qcow2 "$_CACHED_VHDX" "$_CACHED_QCOW2"
    echo "  Conversion complete."
fi

# Create a working copy for setup
echo "Creating setup disk from cached image..."
cp "$_CACHED_QCOW2" "$_SETUP_QCOW2"
# Resize disk to give Windows room to install updates/features
qemu-img resize "$_SETUP_QCOW2" 64G

# --- Prepare UEFI and TPM ---

echo "Preparing UEFI firmware and TPM..."

_QEMU_PREFIX=$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")
_UEFI_CODE="$_QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"
_UEFI_VARS_TEMPLATE="$_QEMU_PREFIX/share/qemu/edk2-aarch64-vars.fd"

if [[ ! -f "$_UEFI_CODE" ]]; then
    echo "ERROR: UEFI firmware not found at $_UEFI_CODE"
    echo "Ensure qemu is installed via Homebrew: brew install qemu"
    exit 1
fi

if [[ ! -f "$_UEFI_VARS_TEMPLATE" ]]; then
    echo "ERROR: UEFI vars template not found at $_UEFI_VARS_TEMPLATE"
    exit 1
fi

# Create writable copy of UEFI vars
cp "$_UEFI_VARS_TEMPLATE" "$_SETUP_EFIVARS"

# Create TPM state directory and start swtpm
mkdir -p "$_SETUP_TPM_DIR"
_TPM_SOCKET="$_SETUP_TPM_DIR/swtpm-sock"

swtpm socket \
    --tpmstate "dir=$_SETUP_TPM_DIR" \
    --ctrl "type=unixio,path=$_TPM_SOCKET" \
    --tpm2 \
    --log "level=0" &
_SWTPM_PID=$!

# Give swtpm a moment to start
sleep 1
if ! kill -0 "$_SWTPM_PID" 2>/dev/null; then
    echo "ERROR: swtpm failed to start"
    exit 1
fi
echo "  swtpm running (PID: $_SWTPM_PID)"

# --- Boot with QEMU ---

echo "Booting Windows VM with QEMU..."
echo "  VNC available at vnc://localhost:590${_VNC_DISPLAY}"
echo "  SSH will be forwarded on localhost:$_SSH_PORT"

qemu-system-aarch64 \
    -machine virt,highmem=on,gic-version=3 \
    -accel hvf \
    -cpu host \
    -m 4096 \
    -drive "if=pflash,format=raw,file=$_UEFI_CODE,readonly=on" \
    -drive "if=pflash,format=raw,file=$_SETUP_EFIVARS" \
    -chardev "socket,id=chrtpm,path=$_TPM_SOCKET" \
    -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
    -device "tpm-tis-sysbus,tpmdev=tpm0" \
    -drive "file=$_SETUP_QCOW2,if=virtio,format=qcow2" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp::${_SSH_PORT}-:22" \
    -vnc ":${_VNC_DISPLAY}" \
    -display none &
_QEMU_PID=$!

sleep 1
if ! kill -0 "$_QEMU_PID" 2>/dev/null; then
    echo "ERROR: QEMU does not appear to have started"
    exit 1
fi
echo "  QEMU running (PID: $_QEMU_PID)"

# --- Set up SSH_ASKPASS for password auth ---
# NOTE: The initial password for the evaluation image is uncertain.
# Common defaults include no password, "Password1", or "Passw0rd!".
# Update _INITIAL_PASS if the evaluation image uses a different password.

_INITIAL_PASS=""
_ASKPASS_FILE=$(mktemp)
cat > "$_ASKPASS_FILE" << EOF
#!/bin/bash
echo '$_INITIAL_PASS'
EOF
chmod 700 "$_ASKPASS_FILE"
export SSH_ASKPASS="$_ASKPASS_FILE"
export SSH_ASKPASS_REQUIRE="force"
export DISPLAY=:0

# --- Wait for SSH ---
# NOTE: The Windows evaluation image may not have SSH pre-installed.
# If this wait times out, you may need to:
#   1. Connect via VNC (vnc://localhost:5901) to complete initial Windows setup
#   2. Manually install OpenSSH Server via Settings > Optional Features
#   3. Re-run this script once SSH is available
# The initial OOBE (Out of Box Experience) can take 5-15 minutes.

echo ""
echo "Waiting for Windows to boot and SSH to become available..."
echo "  This can take 10-15 minutes for initial OOBE setup."
echo "  If it times out, connect via VNC to complete setup manually."
echo -n "Waiting for SSH..."

_SSH_READY=false
for i in $(seq 1 120); do
    if ssh $_SSH_OPTS -p "$_SSH_PORT" "$_WIN_USER@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
        _SSH_READY=true
        echo " ready."
        break
    fi
    echo -n "."
    sleep 5
done

if ! $_SSH_READY; then
    echo ""
    echo "ERROR: SSH not reachable within 600s"
    echo "The Windows evaluation image may need manual OOBE setup via VNC."
    echo "Connect to vnc://localhost:590${_VNC_DISPLAY} and complete setup,"
    echo "then install OpenSSH Server and re-run this script."
    exit 1
fi

# --- Helper functions ---

vm_ssh() {
    ssh $_SSH_OPTS -p "$_SSH_PORT" "$_WIN_USER@localhost" "$1"
}

vm_scp() {
    scp $_SSH_OPTS -P "$_SSH_PORT" "$1" "$_WIN_USER@localhost:$2"
}

# --- Install OpenSSH Server (if not pre-installed) ---

echo "Ensuring OpenSSH Server is installed..."
_SSHD_STATUS=$(vm_ssh "powershell -Command \"Get-Service sshd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status\"" 2>/dev/null || true)

if [[ "$_SSHD_STATUS" != *"Running"* ]]; then
    echo "  Installing OpenSSH Server..."
    vm_ssh "powershell -Command \"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\""
    vm_ssh "powershell -Command \"Set-Service -Name sshd -StartupType Automatic\""
    vm_ssh "powershell -Command \"Start-Service sshd\""
    # Add firewall rule if needed
    vm_ssh "powershell -Command \"if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }\""
    echo "  OpenSSH Server installed and started."
else
    echo "  OpenSSH Server already running."
fi

# --- Create admin account and install SSH key ---

echo "Creating 'admin' account..."
# Create local user 'admin' with password 'admin', add to Administrators
vm_ssh "powershell -Command \"if (-not (Get-LocalUser -Name admin -ErrorAction SilentlyContinue)) { \\\$pw = ConvertTo-SecureString '$_ADMIN_PASS' -AsPlainText -Force; New-LocalUser -Name admin -Password \\\$pw -FullName 'Admin' -Description 'GUIVision admin account' -PasswordNeverExpires; Add-LocalGroupMember -Group Administrators -Member admin }\""

# Set autologin via registry
echo "Configuring autologin for 'admin'..."
vm_ssh "powershell -Command \"Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name AutoAdminLogon -Value 1\""
vm_ssh "powershell -Command \"Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name DefaultUserName -Value admin\""
vm_ssh "powershell -Command \"Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name DefaultPassword -Value '$_ADMIN_PASS'\""

# Install SSH key for admin
echo "Installing SSH key for 'admin'..."
_SSH_KEY_CONTENT=$(cat "$_SSH_KEY")
vm_ssh "powershell -Command \"
    \\\$keyDir = 'C:\\ProgramData\\ssh';
    \\\$keyFile = 'C:\\ProgramData\\ssh\\administrators_authorized_keys';
    if (-not (Test-Path \\\$keyDir)) { New-Item -ItemType Directory -Path \\\$keyDir -Force };
    Set-Content -Path \\\$keyFile -Value '$_SSH_KEY_CONTENT' -Encoding UTF8;
    icacls \\\$keyFile /inheritance:r /grant 'SYSTEM:(R)' /grant 'BUILTIN\\Administrators:(R)';
    takeown /F \$keyFile /A
\""

# Restart sshd to pick up key changes
vm_ssh "powershell -Command \"Restart-Service sshd\""
sleep 3

# Switch to admin user and verify key-based auth.
# NOTE: Changing _WIN_USER here intentionally affects all subsequent vm_ssh calls,
# which should target the 'admin' account from this point onward.
echo "Verifying SSH key auth for 'admin'..."
_WIN_USER="admin"
unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY

if ssh $_SSH_OPTS -p "$_SSH_PORT" "admin@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
    echo "SSH key auth verified for 'admin'."
else
    # Try with password auth as fallback to diagnose
    echo "WARNING: Key-based SSH auth for 'admin' failed."
    echo "  Attempting password auth to diagnose..."
    _ASKPASS_FILE_ADMIN=$(mktemp)
    cat > "$_ASKPASS_FILE_ADMIN" << EOF
#!/bin/bash
echo '$_ADMIN_PASS'
EOF
    chmod 700 "$_ASKPASS_FILE_ADMIN"
    export SSH_ASKPASS="$_ASKPASS_FILE_ADMIN"
    export SSH_ASKPASS_REQUIRE="force"
    export DISPLAY=:0
    if ssh $_SSH_OPTS -p "$_SSH_PORT" "admin@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
        echo "  Password auth works. Key configuration may need adjustment."
        echo "  Continuing with password auth for now..."
    else
        echo "ERROR: Cannot SSH as 'admin' with either key or password auth."
        rm -f "$_ASKPASS_FILE_ADMIN" 2>/dev/null || true
        exit 1
    fi
    rm -f "$_ASKPASS_FILE_ADMIN" 2>/dev/null || true
    unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
fi

# --- Disable machine-wide clutter (HKLM changes apply before reboot) ---

echo "Disabling machine-wide desktop clutter..."

# Disable Cortana
vm_ssh "powershell -Command \"
    \\\$path = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name AllowCortana -Value 0 -Type DWord
\""

# Disable Windows Update auto-restart
vm_ssh "powershell -Command \"
    \\\$path = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name AUOptions -Value 2 -Type DWord
\""

# --- Reboot, verify, shutdown ---

echo -n "Rebooting to apply settings..."
vm_ssh "shutdown /r /t 0" 2>/dev/null || true

# Wait for SSH to drop (reboot) then come back
sleep 15
for i in $(seq 1 120); do
    if ssh $_SSH_OPTS -p "$_SSH_PORT" "admin@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
        echo " back online."
        break
    fi
    echo -n "."
    sleep 5
done

if ! ssh $_SSH_OPTS -p "$_SSH_PORT" "admin@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
    echo ""
    echo "ERROR: VM did not come back online after reboot"
    exit 1
fi

# Give the desktop a moment to fully load after login
sleep 10

# --- Set wallpaper and per-user desktop clutter (HKCU) ---
# These run after reboot so they target the admin user's registry hive,
# which is loaded once admin is logged in via autologin.

echo "Setting wallpaper to solid gray..."
_HELPER_SRC="$(cd "$(dirname "$0")" && pwd)/helpers/set-wallpaper.ps1"
if [[ -f "$_HELPER_SRC" ]]; then
    vm_scp "$_HELPER_SRC" "C:/Users/admin/set-wallpaper.ps1"
    vm_ssh "powershell -ExecutionPolicy Bypass -File C:\\Users\\admin\\set-wallpaper.ps1 808080"
    vm_ssh "powershell -Command \"Remove-Item C:\\Users\\admin\\set-wallpaper.ps1\""
else
    echo "WARNING: set-wallpaper.ps1 not found at $_HELPER_SRC — skipping wallpaper"
fi

echo "Disabling per-user desktop clutter..."

# Disable widgets (TaskbarDa = taskbar data/widgets)
vm_ssh "powershell -Command \"Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced' -Name TaskbarDa -Value 0 -Type DWord\""

# Disable notifications
vm_ssh "powershell -Command \"
    \\\$path = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name ToastEnabled -Value 0 -Type DWord
\""

# Disable first-run experience / suggested content
vm_ssh "powershell -Command \"
    \\\$path = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-338389Enabled -Value 0 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-310093Enabled -Value 0 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-338388Enabled -Value 0 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-338393Enabled -Value 0 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-353694Enabled -Value 0 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name SubscribedContent-353696Enabled -Value 0 -Type DWord
\""

# Disable search highlights
vm_ssh "powershell -Command \"
    \\\$path = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\SearchSettings';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name IsDynamicSearchBoxEnabled -Value 0 -Type DWord
\""

# --- Shutdown ---

if ! kill -0 "$_QEMU_PID" 2>/dev/null; then
    echo "ERROR: QEMU process died unexpectedly"
    exit 1
fi

echo "Shutting down VM..."
vm_ssh "shutdown /s /t 0" 2>/dev/null || true

echo -n "Waiting for shutdown..."
for i in $(seq 1 60); do
    if [[ -z "$_QEMU_PID" ]] || ! kill -0 "$_QEMU_PID" 2>/dev/null; then
        echo " done."
        break
    fi
    echo -n "."
    sleep 2
done
if [[ -n "$_QEMU_PID" ]] && kill -0 "$_QEMU_PID" 2>/dev/null; then
    echo " forcing stop."
    kill "$_QEMU_PID" 2>/dev/null || true
    wait "$_QEMU_PID" 2>/dev/null || true
fi

# Stop swtpm
if [[ -n "$_SWTPM_PID" ]] && kill -0 "$_SWTPM_PID" 2>/dev/null; then
    kill "$_SWTPM_PID" 2>/dev/null || true
    wait "$_SWTPM_PID" 2>/dev/null || true
fi
_SWTPM_PID=""

# --- Finalize golden ---

echo "Creating golden image '$_NAME'..."
mv "$_SETUP_QCOW2" "$_GOLDEN_DIR/$_NAME.qcow2"
mv "$_SETUP_EFIVARS" "$_GOLDEN_DIR/$_NAME-efivars.fd"
mv "$_SETUP_TPM_DIR" "$_GOLDEN_DIR/$_NAME-tpm"

# Prevent cleanup trap from deleting the golden
_GOLDEN_DONE=true
_QEMU_PID=""

echo ""
echo "Golden image '$_NAME' created successfully."
echo "  Disk:    $_GOLDEN_DIR/$_NAME.qcow2"
echo "  UEFI:    $_GOLDEN_DIR/$_NAME-efivars.fd"
echo "  TPM:     $_GOLDEN_DIR/$_NAME-tpm/"
echo ""
echo "Use it with:"
echo "  scripts/test-integration.sh --base $_NAME"
echo "  source scripts/vm-start.sh --base $_NAME"
