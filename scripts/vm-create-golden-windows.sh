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
#   --iso PATH          Path to a Windows 11 ARM64 evaluation ISO file
#
# The --iso option is required on first run (unless a cached install already
# exists at ~/.guivision/cache/). Download the ISO from:
#   https://www.microsoft.com/en-us/software-download/windows11arm64
# Download the ARM64 ISO from that page.
#
# The Windows installation is fully automated via autounattend.xml, which is
# served to Windows Setup on a virtual USB drive. The script boots from the
# ISO, installs Windows unattended (including OpenSSH Server), and waits for
# SSH to become reachable. VNC is available for monitoring progress.
# Typical install time: 20-40 minutes.
#
# Prerequisites:
#   - qemu-system-aarch64 installed (brew install qemu)
#   - qemu-img installed (comes with qemu)
#   - swtpm installed (brew install swtpm)
#   - SSH public key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub
#
# What this creates:
#   A QEMU VM installed from a Microsoft evaluation ISO with:
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
trap 'echo "SCRIPT ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

_VERSION="11"
_NAME=""
_WIN_USER="admin"
_ADMIN_PASS="admin"
_SETUP_PREFIX="guivision-setup-$$"
_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30"
_SSH_PORT=2222
_VNC_DISPLAY=1
_QEMU_PID=""
_SWTPM_PID=""
_ASKPASS_FILE=""
_GOLDEN_DONE=false
_ISO_PATH=""

_GOLDEN_DIR="$HOME/.guivision/golden"
_CACHE_DIR="$HOME/.guivision/cache"

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) _VERSION="$2"; shift 2 ;;
        --name)    _NAME="$2"; shift 2 ;;
        --iso)     _ISO_PATH="$2"; shift 2 ;;
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
    if [[ -n "${_KEYPRESS_PID:-}" ]] && kill -0 "$_KEYPRESS_PID" 2>/dev/null; then
        kill "$_KEYPRESS_PID" 2>/dev/null || true
    fi
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
    rm -f "$_CACHE_DIR/${_SETUP_PREFIX}-monitor.sock" 2>/dev/null || true
    rm -f "$_CACHE_DIR/${_SETUP_PREFIX}-autounattend.img" 2>/dev/null || true
    rm -f "$_CACHE_DIR/${_SETUP_PREFIX}-qemu.log" 2>/dev/null || true
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

# --- Locate ISO and prepare setup disk ---

_CACHED_ISO="$_CACHE_DIR/windows-${_VERSION}-arm64-eval.iso"

if [[ -n "$_ISO_PATH" ]]; then
    if [[ ! -f "$_ISO_PATH" ]]; then
        echo "ERROR: ISO file not found: $_ISO_PATH"
        exit 1
    fi
    echo "Copying ISO to cache..."
    cp "$_ISO_PATH" "$_CACHED_ISO"
elif [[ ! -f "$_CACHED_ISO" ]]; then
    echo "ERROR: No Windows ARM64 evaluation ISO available."
    echo ""
    echo "Download one from Microsoft and pass it with --iso:"
    echo "  1. Visit https://www.microsoft.com/en-us/software-download/windows11arm64"
    echo "  2. Download the ARM64 ISO"
    echo "  3. Run: $0 --iso /path/to/downloaded.iso"
    echo ""
    echo "The ISO is cached after first use, so subsequent runs won't need --iso."
    exit 1
fi

# Create a blank disk for Windows installation
echo "Creating setup disk (64GB)..."
qemu-img create -f qcow2 "$_SETUP_QCOW2" 64G

# Create autounattend media (FAT disk image with autounattend.xml and drivers).
# Mounted as a USB flash drive so Windows Setup finds autounattend.xml
# during its implicit answer file search on removable disk drives.
echo "Creating autounattend media..."
_AUTOUNATTEND_IMG="$_CACHE_DIR/${_SETUP_PREFIX}-autounattend.img"
_HELPERS_DIR="$(cd "$(dirname "$0")" && pwd)/helpers"
_AUTOUNATTEND_TMP=$(mktemp -d)
cp "$_HELPERS_DIR/autounattend.xml" "$_AUTOUNATTEND_TMP/autounattend.xml"

# Create startup.nsh for UEFI Shell fallback.
# If UEFI firmware can't auto-discover the USB boot device, it drops to
# the UEFI Shell, which auto-executes startup.nsh after 5 seconds.
# This script finds and launches the Windows ISO's boot loader.
cat > "$_AUTOUNATTEND_TMP/startup.nsh" << 'NSHEOF'
FS0:\efi\boot\bootaa64.efi
FS1:\efi\boot\bootaa64.efi
FS2:\efi\boot\bootaa64.efi
FS3:\efi\boot\bootaa64.efi
NSHEOF

# Extract VirtIO ARM64 network driver from virtio-win ISO.
# autounattend.xml's PnpCustomizationsWinPE section tells Windows Setup
# to load these during install so virtio-net-pci works in the installed OS.
_VIRTIO_ISO="$_CACHE_DIR/virtio-win.iso"
if [[ ! -f "$_VIRTIO_ISO" ]]; then
    echo "Downloading virtio-win drivers (~600MB, cached after first run)..."
    curl -L -o "$_VIRTIO_ISO" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
fi
_VIRTIO_MNT=$(mktemp -d)
hdiutil attach "$_VIRTIO_ISO" -mountpoint "$_VIRTIO_MNT" -readonly -nobrowse -quiet
mkdir -p "$_AUTOUNATTEND_TMP/drivers"
cp "$_VIRTIO_MNT/NetKVM/w11/ARM64/"* "$_AUTOUNATTEND_TMP/drivers/"
hdiutil detach "$_VIRTIO_MNT" -quiet
rmdir "$_VIRTIO_MNT" 2>/dev/null || true
echo "  NetKVM ARM64 driver included."

# Build a FAT-formatted disk image (appears as USB flash drive to Windows).
# Windows Setup only searches removable *disk* drives for Autounattend.xml,
# not CD-ROM drives, so a FAT image is required (not ISO).
hdiutil create -size 32m -fs "MS-DOS FAT16" -volname UNATTEND \
    -srcfolder "$_AUTOUNATTEND_TMP" -ov "$_AUTOUNATTEND_IMG" -quiet
qemu-img convert -f dmg -O raw "$_AUTOUNATTEND_IMG.dmg" "$_AUTOUNATTEND_IMG"
rm -f "$_AUTOUNATTEND_IMG.dmg"
rm -rf "$_AUTOUNATTEND_TMP"

# --- Prepare UEFI and TPM ---

echo "Preparing UEFI firmware and TPM..."

_QEMU_PREFIX=$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")
_UEFI_CODE="$_QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"
if [[ ! -f "$_UEFI_CODE" ]]; then
    echo "ERROR: UEFI firmware not found at $_UEFI_CODE"
    echo "Ensure qemu is installed via Homebrew: brew install qemu"
    exit 1
fi

# AArch64 QEMU doesn't ship a vars template — create a blank 64MB file.
# The UEFI firmware initializes it on first boot.
truncate -s 64M "$_SETUP_EFIVARS"

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

_QEMU_LOG="$_CACHE_DIR/${_SETUP_PREFIX}-qemu.log"
_MONITOR_SOCK="$_CACHE_DIR/${_SETUP_PREFIX}-monitor.sock"
_VNC_PASS="admin"

echo "Booting Windows VM from ISO with QEMU..."
echo "  VNC: vnc://localhost:590${_VNC_DISPLAY}"
echo "  SSH will be forwarded on localhost:$_SSH_PORT"
echo "  QEMU log: $_QEMU_LOG"

qemu-system-aarch64 \
    -machine virt,highmem=on,gic-version=3 \
    -accel hvf \
    -cpu host \
    -smp 4 \
    -m 4096 \
    -drive "if=pflash,format=raw,file=$_UEFI_CODE,readonly=on" \
    -drive "if=pflash,format=raw,file=$_SETUP_EFIVARS" \
    -chardev "socket,id=chrtpm,path=$_TPM_SOCKET" \
    -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
    -device "tpm-tis-device,tpmdev=tpm0" \
    -drive "file=$_SETUP_QCOW2,if=none,id=hd0,format=qcow2" \
    -device "nvme,drive=hd0,serial=boot,bootindex=0" \
    -device "ramfb" \
    -device "qemu-xhci" \
    -device "usb-kbd" \
    -device "usb-tablet" \
    -drive "file=$_CACHED_ISO,if=none,id=cd0,media=cdrom,readonly=on" \
    -device "usb-storage,drive=cd0,bootindex=1" \
    -drive "file=$_AUTOUNATTEND_IMG,if=none,id=unattend,format=raw" \
    -device "usb-storage,drive=unattend,removable=on" \
    -device "virtio-net-pci,netdev=net0" \
    -netdev "user,id=net0,hostfwd=tcp::${_SSH_PORT}-:22" \
    -vnc ":${_VNC_DISPLAY},password=on" \
    -monitor "unix:$_MONITOR_SOCK,server,nowait" \
    -serial "file:$_QEMU_LOG" \
    -d guest_errors \
    -display none 2>>"$_QEMU_LOG" &
_QEMU_PID=$!

sleep 2
if ! kill -0 "$_QEMU_PID" 2>/dev/null; then
    echo "ERROR: QEMU does not appear to have started"
    echo "Log output:"
    cat "$_QEMU_LOG" 2>/dev/null || true
    exit 1
fi
echo "  QEMU running (PID: $_QEMU_PID)"

# --- Set VNC password and send keypresses ---
# Disable set -e for monitor interactions — nc/grep failures must not kill the script.

set +e

# Set VNC password (macOS Screen Sharing requires one)
# Set VNC password (retry to ensure monitor socket is ready)
for _vnc_try in 1 2 3; do
    (echo "set_password vnc $_VNC_PASS"; sleep 1) | nc -U "$_MONITOR_SOCK" >/dev/null 2>&1 && break
    sleep 1
done

echo ""
echo "--- QEMU device diagnostics ---"
_MON_OUT=$( (echo "info block"; sleep 1) | nc -U "$_MONITOR_SOCK" 2>/dev/null )
echo "Block devices:"
echo "$_MON_OUT" | grep -E "(cd0|unattend|hd0)" || echo "  (none detected)"
echo "--- end diagnostics ---"
echo ""

# Send periodic keypresses to dismiss "Press any key to boot from CD..." prompt.
# The Windows boot loader on the ISO requires a keypress within ~5 seconds.
# Limited to 8 iterations (~8s) to stop BEFORE Windows Setup's Cancel button
# becomes focused — Enter keys after that would trigger the Cancel dialog.
(
    for i in $(seq 1 8); do
        sleep 1
        echo "sendkey ret"
    done
) | nc -U "$_MONITOR_SOCK" >/dev/null 2>&1 &
_KEYPRESS_PID=$!

set -e

# --- Automated installation via autounattend.xml ---
# Windows Setup automatically finds autounattend.xml on the USB drive and:
#   1. Bypasses TPM/SecureBoot/RAM checks via LabConfig registry entries
#   2. Loads VirtIO network driver (NetKVM) via PnpCustomizationsWinPE
#   3. Partitions the NVMe disk (EFI + MSR + NTFS)
#   4. Applies the Windows image from the ISO
#   5. Creates admin/admin user with autologin
#   6. Installs and starts OpenSSH Server
# The VM reboots several times during this process. No manual intervention needed.

echo ""
echo "=========================================================="
echo "  Automated Windows installation via autounattend.xml"
echo "=========================================================="
echo ""
echo "  Windows Setup will:"
echo "    1. Partition disk and install Windows (~15-25 min)"
echo "    2. Configure admin user and autologin"
echo "    3. Install OpenSSH Server"
echo ""
echo "  Monitor progress via VNC:"
echo "    open vnc://localhost:590${_VNC_DISPLAY}"
echo "    VNC password: $_VNC_PASS"
echo "=========================================================="
echo ""

# --- Set up SSH_ASKPASS for password auth (admin/admin) ---

_ASKPASS_FILE=$(mktemp)
cat > "$_ASKPASS_FILE" << EOF
#!/bin/bash
echo '$_ADMIN_PASS'
EOF
chmod 700 "$_ASKPASS_FILE"
export SSH_ASKPASS="$_ASKPASS_FILE"
export SSH_ASKPASS_REQUIRE="force"
export DISPLAY=:0

# --- Wait for SSH ---
# autounattend.xml handles user creation, autologin, and OpenSSH installation
# via FirstLogonCommands. SSH becomes reachable once the first login completes.

echo "Waiting for SSH on localhost:$_SSH_PORT..."
echo "(Typical wait: 20-40 minutes for install + OpenSSH setup)"

_SSH_READY=false
_LAST_LOG_SIZE=0
for i in $(seq 1 120); do
    if ! kill -0 "$_QEMU_PID" 2>/dev/null; then
        echo ""
        echo "ERROR: QEMU process died during installation"
        echo "Last QEMU log output:"
        tail -20 "$_QEMU_LOG" 2>/dev/null || true
        exit 1
    fi
    if ssh $_SSH_OPTS -p "$_SSH_PORT" "$_WIN_USER@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
        _SSH_READY=true
        echo ""
        echo "SSH ready."
        break
    fi

    # Print elapsed time and any new QEMU log output every 30s
    _ELAPSED=$(( i * 30 ))
    _MINS=$(( _ELAPSED / 60 ))
    _SECS=$(( _ELAPSED % 60 ))
    printf "\r  [%02d:%02d] Waiting for SSH..." "$_MINS" "$_SECS"

    # Show new log lines (if any) every 2 minutes
    if (( i % 4 == 0 )); then
        _CUR_LOG_SIZE=$(wc -c < "$_QEMU_LOG" 2>/dev/null || echo 0)
        if [[ "$_CUR_LOG_SIZE" -gt "$_LAST_LOG_SIZE" ]]; then
            echo ""
            echo "  --- QEMU log (new output) ---"
            tail -5 "$_QEMU_LOG" 2>/dev/null || true
            echo "  ---"
            _LAST_LOG_SIZE=$_CUR_LOG_SIZE
        fi
    fi
    sleep 30
done

if ! $_SSH_READY; then
    echo ""
    echo "ERROR: SSH not reachable within 60 minutes"
    echo "Connect via VNC to diagnose: open vnc://localhost:590${_VNC_DISPLAY}"
    echo ""
    echo "QEMU log tail:"
    tail -30 "$_QEMU_LOG" 2>/dev/null || true
    exit 1
fi

# --- Helper functions ---

vm_ssh() {
    ssh $_SSH_OPTS -p "$_SSH_PORT" "$_WIN_USER@localhost" "$1"
}

vm_scp() {
    scp $_SSH_OPTS -P "$_SSH_PORT" "$1" "$_WIN_USER@localhost:$2"
}

# --- Install SSH key ---
# OpenSSH Server, admin account, and autologin are already configured
# by autounattend.xml. We just need to install the host SSH key.

echo "Installing SSH key for 'admin'..."
_SSH_KEY_CONTENT=$(cat "$_SSH_KEY")
# Windows OpenSSH requires administrators_authorized_keys for admin users,
# with strict ACLs: only SYSTEM and BUILTIN\Administrators may have access.
# Order matters: take ownership first, then reset ACLs, then set correct ones.
# Use ASCII encoding to avoid UTF-8 BOM which OpenSSH can't parse.
vm_ssh "powershell -Command \"
    \\\$keyFile = 'C:\\ProgramData\\ssh\\administrators_authorized_keys';
    [IO.File]::WriteAllText(\\\$keyFile, '$_SSH_KEY_CONTENT');
    takeown /F \\\$keyFile /A;
    icacls \\\$keyFile /inheritance:r;
    icacls \\\$keyFile /remove 'admin';
    icacls \\\$keyFile /grant 'SYSTEM:(R)';
    icacls \\\$keyFile /grant 'BUILTIN\\Administrators:(R)'
\""

# Restart sshd to pick up key changes
vm_ssh "powershell -Command \"Restart-Service sshd\""
sleep 3

# Verify key-based auth works without password
echo "Verifying SSH key auth..."
unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY

if ssh $_SSH_OPTS -p "$_SSH_PORT" "admin@localhost" "echo ok" 2>/dev/null | grep -q "ok"; then
    echo "SSH key auth verified."
else
    echo "WARNING: Key-based SSH auth failed. Falling back to password auth..."
    export SSH_ASKPASS="$_ASKPASS_FILE"
    export SSH_ASKPASS_REQUIRE="force"
    export DISPLAY=:0
fi

# --- Disable machine-wide clutter (HKLM changes apply before reboot) ---

echo "Disabling machine-wide desktop clutter..."

# Disable Cortana
vm_ssh "powershell -Command \"
    \\\$path = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name AllowCortana -Value 0 -Type DWord
\""

# Disable Windows Update auto-restart (let updates check/install during golden
# creation so clones inherit a fully-updated, settled state)
vm_ssh "powershell -Command \"
    \\\$path = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU';
    if (-not (Test-Path \\\$path)) { New-Item -Path \\\$path -Force };
    Set-ItemProperty -Path \\\$path -Name NoAutoRebootWithLoggedOnUsers -Value 1 -Type DWord;
    Set-ItemProperty -Path \\\$path -Name AUOptions -Value 2 -Type DWord
\""

# Disable first-logon animation so clones don't replay "Getting things ready"
vm_ssh "reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f"

# Disable widgets via group policy (HKCU TaskbarDa is protected by Explorer)
vm_ssh "reg add \"HKLM\\SOFTWARE\\Policies\\Microsoft\\Dsh\" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f"

# --- Write desktop setup script (runs via RunOnce in the desktop session) ---
# HKCU registry writes fail over SSH due to session ACLs. Instead, we write a
# PowerShell script and register it in HKLM RunOnce. On next login, it runs in
# the desktop session where HKCU is fully writable and the wallpaper API works.

echo "Uploading desktop setup script..."
vm_scp "$_HELPERS_DIR/desktop-setup.ps1" "C:\\Windows\\Setup\\Scripts\\desktop-setup.ps1"

# Register the script to run at next login via HKLM RunOnce (HKLM is writable over SSH)
vm_ssh "reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce\" /v DesktopSetup /t REG_SZ /d \"powershell -ExecutionPolicy Bypass -File C:\\Windows\\Setup\\Scripts\\desktop-setup.ps1\" /f"

# --- First reboot: RunOnce applies all HKCU settings in the desktop session ---

echo -n "Rebooting to apply desktop settings..."
vm_ssh "shutdown /r /t 0" 2>/dev/null || true

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

# Wait for the desktop-setup script to complete (signalled by a marker file)
echo -n "Waiting for desktop setup to complete..."
for i in $(seq 1 60); do
    if vm_ssh "if exist C:\\Windows\\Setup\\Scripts\\desktop-setup-done.txt echo done" 2>/dev/null | grep -q "done"; then
        echo " done."
        break
    fi
    echo -n "."
    sleep 2
done

if ! vm_ssh "if exist C:\\Windows\\Setup\\Scripts\\desktop-setup-done.txt echo done" 2>/dev/null | grep -q "done"; then
    echo ""
    echo "ERROR: Desktop setup script did not complete"
    exit 1
fi

# Let Windows fully settle — background tasks (search indexing, app readiness,
# component store cleanup) run for minutes after first login.
echo "Waiting 60s for Windows to settle..."
sleep 60

# --- Second reboot: wallpaper and taskbar changes take full effect on login ---

echo -n "Second reboot to finalize..."
vm_ssh "shutdown /r /t 0" 2>/dev/null || true

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
    echo "ERROR: VM did not come back online after second reboot"
    exit 1
fi

echo "Waiting 30s for final settle..."
sleep 30

# --- Clean desktop before shutdown ---
# Close any startup apps that opened windows (Get Started, Edge, Tips, etc.)
# so clones inherit a clean desktop with no open windows.
# Note: do NOT restart Explorer over SSH — it runs in the SSH session context,
# not the desktop session, leaving a black screen.
echo "Cleaning desktop state..."
vm_ssh "powershell -Command \"
    \\\$apps = @('GetStarted','Video.UI','HelpPane','SearchHost','SearchApp',
                'PhoneExperienceHost','msedge','MicrosoftEdge*','Widgets');
    foreach (\\\$a in \\\$apps) {
        Get-Process -Name \\\$a -ErrorAction SilentlyContinue | Stop-Process -Force
    }
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
