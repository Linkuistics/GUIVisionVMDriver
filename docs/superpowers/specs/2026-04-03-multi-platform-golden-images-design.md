# Multi-Platform Golden VM Images

Design spec for creating golden VM images for macOS, Linux, and Windows 11 ARM, and updating the downstream VM lifecycle scripts to support all three platforms.

## Scope

1. Rename `vm-create-golden.sh` to `vm-create-golden-macos.sh`
2. New `vm-create-golden-linux.sh` (tart, Ubuntu Desktop)
3. New `vm-create-golden-windows.sh` (QEMU, Windows 11 ARM evaluation image)
4. Update `vm-start.sh` for multi-platform support
5. Update `vm-stop.sh` for multi-platform support
6. Update `test-integration.sh` for multi-platform support
7. Update Swift integration tests for renamed env vars
8. New helper: `scripts/helpers/set-wallpaper.ps1` (Windows wallpaper)

## Conventions

All platforms share:

- User account: `admin` / password: `admin`
- SSH key auth via host's `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`
- Solid gray wallpaper for reliable screenshot analysis
- Autologin enabled (desktop ready on boot without manual login)
- Notifications, widgets, and session restore disabled
- Golden images are never run directly; clone for each test session

**SSH shell per platform:**
- macOS: `zsh` (default shell)
- Linux: `bash` (default shell)
- Windows: `PowerShell` (OpenSSH for Windows default) — not bash or cmd

## Golden Image Naming

- macOS: `guivision-golden-macos-{version}` (e.g. `guivision-golden-macos-tahoe`)
- Linux: `guivision-golden-linux-{version}` (e.g. `guivision-golden-linux-noble`)
- Windows: `guivision-golden-windows-{version}` (e.g. `guivision-golden-windows-11`)

## Environment Variables

All scripts export `GUIVISION_*` (replacing the old `GUIVISION_TEST_*` prefix):

| Variable | Description | Example (macOS) | Example (Windows) |
|----------|-------------|-----------------|-------------------|
| `GUIVISION_VNC` | VNC host:port | `192.168.64.5:5900` | `localhost:5901` |
| `GUIVISION_VNC_PASSWORD` | VNC password | `abc123` | (empty or set) |
| `GUIVISION_PLATFORM` | Target OS | `macos` | `windows` |
| `GUIVISION_SSH` | SSH user@host | `admin@192.168.64.5` | `admin@localhost -p 2222` |
| `GUIVISION_VM_NAME` | VM instance name | `guivision-test-12345` | `guivision-test-12345` |
| `GUIVISION_VM_PID` | VM process PID | `54321` | `54321` |
| `GUIVISION_VM_TOOL` | VM tool in use | `tart` | `qemu` |

## VM Tools

| Platform | Tool | Image storage |
|----------|------|---------------|
| macOS | tart | tart internal storage |
| Linux | tart | tart internal storage |
| Windows | QEMU (`qemu-system-aarch64`) | `~/.guivision/golden/` |

## Prerequisites

| Platform | Required on host |
|----------|-----------------|
| macOS | `tart` |
| Linux | `tart` |
| Windows | `qemu`, `swtpm` (via `brew install qemu swtpm`) |
| All | SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` |

---

## Script: `vm-create-golden-macos.sh`

Renamed from `vm-create-golden.sh`. No functional changes beyond updating env var names in the usage output.

### Options

- `--version VERSION` — macOS version: tahoe, sequoia, sonoma (default: tahoe)
- `--name NAME` — Golden image name (default: `guivision-golden-macos-{version}`)

---

## Script: `vm-create-golden-linux.sh`

Creates a golden Linux VM using tart with Ubuntu Desktop installed.

### Options

- `--version VERSION` — Ubuntu codename: noble, jammy (default: noble)
- `--name NAME` — Golden image name (default: `guivision-golden-linux-{version}`)

### Base Image

`ghcr.io/cirruslabs/ubuntu:{version}` — Cirrus Labs ARM Ubuntu server image. Ships with user `admin` / password `admin` and SSH enabled.

### Setup Steps

1. Preflight: check tart, find SSH key
2. Clone vanilla: `tart clone ghcr.io/cirruslabs/ubuntu:{version} guivision-setup-$$`
3. Boot: `tart run --no-graphics` (no VNC needed during setup, SSH only)
4. Wait for SSH: poll `tart ip` + SSH connectivity
5. Install SSH key: inject host pubkey into `~/.ssh/authorized_keys`
6. Install Ubuntu Desktop: `sudo apt update && sudo apt install -y ubuntu-desktop-minimal`
7. Configure autologin: edit `/etc/gdm3/custom.conf` to auto-login `admin`
8. Solid wallpaper: `gsettings` to set solid gray background
9. Disable screen lock and notifications: `gsettings` commands
10. Reboot cycle: reboot to start GDM with autologin, verify SSH returns
11. Shutdown and clone to golden

### VNC Consideration

Tart provides VNC via `--vnc-experimental` for Linux VMs. If tart's VNC does not work with the GNOME desktop session (e.g. only shows text console), fall back to installing TigerVNC or x11vnc inside the VM. This is resolved during implementation.

---

## Script: `vm-create-golden-windows.sh`

Creates a golden Windows 11 ARM VM using QEMU, starting from a Microsoft evaluation VHDX image.

### Options

- `--version VERSION` — Windows version (default: 11)
- `--name NAME` — Golden image name (default: `guivision-golden-windows-{version}`)

### Base Image Strategy

Primary: Download Microsoft's Windows 11 ARM64 evaluation VHDX, convert to QCOW2 via `qemu-img convert`. The evaluation image is time-limited (90 days) but golden images are cheap to recreate.

Fallback (future): Unattended ISO install via `autounattend.xml`. Not implemented in this iteration.

### QEMU Configuration

- `qemu-system-aarch64` with UEFI firmware (`edk2-aarch64-code.fd`, ships with qemu Homebrew package)
- Virtual TPM via `swtpm` (required by Windows 11)
- VirtIO drivers for disk and network
- Built-in VNC display (`-vnc :N`)
- User-mode networking with SSH port forwarding (`-nic user,hostfwd=tcp::2222-:22`)

### Image Storage

`~/.guivision/golden/` contains:
- `{name}.qcow2` — the golden disk image
- `{name}-efivars.fd` — UEFI variable store
- `{name}-tpm/` — TPM state directory

### Setup Steps

1. Preflight: check `qemu-system-aarch64`, `swtpm`, find SSH key
2. Download evaluation VHDX (if not cached)
3. Convert VHDX to QCOW2: `qemu-img convert -f vhdx -O qcow2`
4. Boot with QEMU: UEFI + TPM + VirtIO + VNC + port-forwarded SSH
5. Wait for SSH: poll `localhost:2222`
6. Install OpenSSH Server: `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` via PowerShell
7. Configure and start sshd service
8. Install SSH key: write host pubkey to `C:\ProgramData\ssh\administrators_authorized_keys`
9. Create/configure `admin` account with password `admin`, grant admin privileges
10. Configure autologin: registry keys at `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
11. Solid wallpaper: run `scripts/helpers/set-wallpaper.ps1` via PowerShell to set solid gray
12. Disable clutter: widgets, notifications, first-run experience, Windows Update auto-restart, Cortana, search highlights (all via registry/PowerShell)
13. Reboot cycle: verify autologin, SSH returns, desktop is clean
14. Shutdown and save QCOW2 as golden

### Uncertainties (resolved during implementation)

- Whether the evaluation VHDX includes VirtIO drivers or needs injection from the VirtIO ISO
- The initial user account name in the evaluation image (may need renaming to `admin`)
- Whether OpenSSH Server is pre-installed in the evaluation image

---

## Script: `vm-start.sh`

Updated to support all three platforms. Must still be sourced.

### New Options

- `--platform macos|linux|windows` (default: `macos`)

Existing options (`--base`, `--name`, `--viewer`, `--no-ssh`) remain.

### Default base image per platform

- `macos` → `guivision-golden-macos-tahoe`
- `linux` → `guivision-golden-linux-noble`
- `windows` → `guivision-golden-windows-11`

### Platform branching

| Concern | macOS / Linux (tart) | Windows (QEMU) |
|---------|---------------------|----------------|
| Clone | `tart clone` | `qemu-img create -f qcow2 -b golden.qcow2 -F qcow2 clone.qcow2` |
| Boot | `tart run --no-graphics --vnc-experimental` | `qemu-system-aarch64` with full flag set |
| VNC discovery | Parse tart stdout for `vnc://` URL | Known at launch (e.g. `localhost:5901`) |
| SSH discovery | `tart ip` + poll port 22 | Port forwarding: `localhost:2222` |
| Exported `GUIVISION_VM_TOOL` | `tart` | `qemu` |

### VNC Viewer

The `--viewer` flag opens macOS Screen Sharing for all platforms (it connects to any VNC host:port).

---

## Script: `vm-stop.sh`

Updated to handle both VM tools. Must still be sourced.

### Behavior per tool

| Concern | tart | QEMU |
|---------|------|------|
| Stop | `tart stop $GUIVISION_VM_NAME` | `kill $GUIVISION_VM_PID` |
| Delete | `tart delete $GUIVISION_VM_NAME` | Remove clone QCOW2 + associated TPM/UEFI files |
| Close VNC viewer | Close Screen Sharing window | Close Screen Sharing window |

Detects tool via `GUIVISION_VM_TOOL` env var. Unsets all `GUIVISION_*` vars.

---

## Script: `test-integration.sh`

Updated for multi-platform support.

### New Options

- `--platform macos|linux|windows` (default: `macos`)

### Changes

- Golden image check uses platform-appropriate lookup (tart list for macOS/Linux, file check for Windows)
- Offers to create missing golden via `vm-create-golden-{platform}.sh`
- Clone/boot/VNC/SSH discovery uses same platform branching as `vm-start.sh`
- Cleanup trap uses `GUIVISION_VM_TOOL` for teardown
- Swift test invocation unchanged (env vars drive platform behavior)

---

## Swift Integration Tests

Update `Tests/IntegrationTests/` to read renamed env vars:

| Old | New |
|-----|-----|
| `GUIVISION_TEST_VNC` | `GUIVISION_VNC` |
| `GUIVISION_TEST_VNC_PASSWORD` | `GUIVISION_VNC_PASSWORD` |
| `GUIVISION_TEST_PLATFORM` | `GUIVISION_PLATFORM` |
| `GUIVISION_TEST_SSH` | `GUIVISION_SSH` |
