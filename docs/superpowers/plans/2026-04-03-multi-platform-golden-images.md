# Multi-Platform Golden VM Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create golden VM image scripts for Linux and Windows 11 ARM, and update all downstream VM lifecycle scripts for multi-platform support.

**Architecture:** Three independent golden creation scripts (macOS via tart, Linux via tart, Windows via QEMU) with a unified `--platform` parameter on `vm-start.sh`, `vm-stop.sh`, and `test-integration.sh`. Environment variables renamed from `GUIVISION_TEST_*` to `GUIVISION_*`.

**Spec:** `docs/superpowers/specs/2026-04-03-multi-platform-golden-images-design.md`

---

### Task 1: Rename macOS golden script and update defaults

**Files:**
- Rename: `scripts/vm-create-golden.sh` → `scripts/vm-create-golden-macos.sh`

- [ ] **Step 1: Rename the file**

`git mv scripts/vm-create-golden.sh scripts/vm-create-golden-macos.sh`

- [ ] **Step 2: Update the default golden image name**

Change the default `_NAME` from `guivision-golden-$_VERSION` to `guivision-golden-macos-$_VERSION` so it follows the new `guivision-golden-{platform}-{version}` convention.

- [ ] **Step 3: Update the usage comment block**

Update the header comment and the final "Use it with:" output lines to reference the new script name and new golden image name.

- [ ] **Step 4: Commit**

`git add -A && git commit -m "refactor: rename vm-create-golden.sh to vm-create-golden-macos.sh"`

---

### Task 2: Create Linux golden image script

**Files:**
- Create: `scripts/vm-create-golden-linux.sh`

The script follows the same overall structure as `vm-create-golden-macos.sh` but targets Ubuntu Desktop on tart.

- [ ] **Step 1: Write the script with preflight and argument parsing**

Options: `--version VERSION` (default: `noble`), `--name NAME` (default: `guivision-golden-linux-$VERSION`).

Preflight: Check `tart` is installed. Find SSH public key (same logic as macOS script). Set up `SSH_ASKPASS` for password auth to the vanilla image (user `admin`, password `admin`).

Base image: `ghcr.io/cirruslabs/ubuntu:$VERSION`

- [ ] **Step 2: Clone, boot, and wait for SSH**

Clone the vanilla image to a temporary setup VM (`guivision-setup-$$`). Boot with `tart run --no-graphics` (no VNC needed during setup). Wait for SSH using `tart ip` + SSH poll loop (same pattern as macOS script). Set up a cleanup trap that stops/deletes the setup VM on exit.

- [ ] **Step 3: Install SSH key**

Same approach as macOS: `mkdir -p ~/.ssh`, scp the host pubkey, append to `authorized_keys`, verify key-based auth works without password.

- [ ] **Step 4: Install Ubuntu Desktop**

Run `sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal` via SSH. This is a long operation (several minutes). Use `DEBIAN_FRONTEND=noninteractive` to prevent interactive prompts.

- [ ] **Step 5: Configure autologin**

Write `/etc/gdm3/custom.conf` via SSH to enable automatic login for user `admin`. The file needs `[daemon]` section with `AutomaticLoginEnable=True` and `AutomaticLogin=admin`.

- [ ] **Step 6: Set solid wallpaper and disable desktop clutter**

Use `dbus-launch gsettings` commands via SSH to:
- Set `org.gnome.desktop.background picture-options` to `none`
- Set `org.gnome.desktop.background primary-color` to `#808080`
- Disable screen lock: `org.gnome.desktop.screensaver lock-enabled` false
- Disable screen blanking: `org.gnome.desktop.session idle-delay` 0
- Disable notifications: `org.gnome.desktop.notifications show-banners` false

Note: `gsettings` requires a dbus session, so prefix commands with `dbus-launch` when running over SSH.

- [ ] **Step 7: Reboot, verify SSH returns, shutdown, and clone to golden**

Reboot the VM via `sudo reboot`. Wait for SSH to drop then come back (same poll pattern as the macOS script's logout cycle). After SSH returns, give the desktop a few seconds to settle. Then `sudo shutdown -h now`, wait for the tart process to exit, clone the setup VM to the golden image name, delete the setup VM.

- [ ] **Step 8: Make executable and commit**

`chmod +x scripts/vm-create-golden-linux.sh`
`git add scripts/vm-create-golden-linux.sh && git commit -m "feat: add Linux golden image creation script"`

---

### Task 3: Create Windows wallpaper helper

**Files:**
- Create: `scripts/helpers/set-wallpaper.ps1`

- [ ] **Step 1: Write the PowerShell script**

A short PowerShell script that accepts a hex color string (e.g. `808080`) and sets a solid wallpaper via:
- Set registry values at `HKCU:\Control Panel\Desktop` for `WallPaper` (empty string) and `WallpaperStyle`
- Set registry value at `HKCU:\Control Panel\Colors` for `Background` to the RGB values
- Call `SystemParametersInfo` via P/Invoke (the `User32.dll` `SystemParametersInfoW` function with `SPI_SETDESKWALLPAPER`) to apply immediately without requiring a logout

- [ ] **Step 2: Commit**

`git add scripts/helpers/set-wallpaper.ps1 && git commit -m "feat: add Windows wallpaper helper script"`

---

### Task 4: Create Windows golden image script

**Files:**
- Create: `scripts/vm-create-golden-windows.sh`

This is the most complex script. It uses QEMU instead of tart and has more setup steps.

- [ ] **Step 1: Write the script with preflight and argument parsing**

Options: `--version VERSION` (default: `11`), `--name NAME` (default: `guivision-golden-windows-$VERSION`).

Preflight checks:
- `qemu-system-aarch64` is installed
- `qemu-img` is installed
- `swtpm` is installed
- SSH public key exists

Define the golden storage directory as `~/.guivision/golden/` and create it if it doesn't exist. Define paths for the golden QCOW2, UEFI vars, and TPM state directory.

- [ ] **Step 2: Download and convert the evaluation VHDX**

Check if a cached VHDX already exists in `~/.guivision/cache/`. If not, download the Windows 11 ARM64 evaluation VHDX from Microsoft. Convert with `qemu-img convert -f vhdx -O qcow2`. Store the QCOW2 as a setup image (not yet golden).

Also prepare:
- Copy the UEFI firmware vars file from the qemu Homebrew installation (`$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd` for code, create a writable copy of `edk2-arm-vars.fd` for the variable store)
- Create a TPM state directory and start `swtpm` in socket mode

- [ ] **Step 3: Boot with QEMU**

Launch `qemu-system-aarch64` in the background with:
- Machine type: `virt` with `highmem=on`
- CPU: `host` with hardware acceleration (`-accel hvf`)
- Memory: 4096M (minimum for Windows 11)
- UEFI firmware (pflash x2: code read-only, vars read-write)
- TPM device connected to the swtpm socket
- VirtIO disk with the setup QCOW2
- VirtIO network with user-mode networking and port forwarding: `hostfwd=tcp::2222-:22`
- VNC display on a chosen port (e.g. `-vnc :1`)
- No graphical window (`-nographic` or just rely on VNC)

Set up a cleanup trap that kills the QEMU process and swtpm on exit.

- [ ] **Step 4: Wait for SSH**

The evaluation image should eventually be accessible via SSH after Windows boots. Poll `ssh -p 2222 localhost` with the evaluation image's default credentials. The default user in Microsoft's evaluation images is typically `User` with password `P@ssw0rd` or similar — this will need to be verified during implementation. Use `SSH_ASKPASS` for initial password auth, same pattern as the tart scripts.

Note: If SSH is not pre-installed in the evaluation image, this step will need to be done differently — possibly via QEMU's guest agent or by mounting the disk image and injecting files. Document this as the first thing to verify.

- [ ] **Step 5: Install and configure OpenSSH Server**

Via SSH (or PowerShell if SSH isn't available yet), run:
- `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
- `Set-Service -Name sshd -StartupType Automatic`
- `Start-Service sshd`
- Configure the firewall rule if needed: `New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22`

- [ ] **Step 6: Create admin account and install SSH key**

Via SSH/PowerShell:
- Create a local user `admin` with password `admin` and add to the Administrators group
- Set autologin: write registry values at `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` — `AutoAdminLogon`=1, `DefaultUserName`=admin, `DefaultPassword`=admin
- Install SSH key: write the host's public key to `C:\ProgramData\ssh\administrators_authorized_keys` and set appropriate ACLs (only SYSTEM and Administrators should have access)
- Verify key-based SSH auth works for the `admin` user

- [ ] **Step 7: Set wallpaper and disable desktop clutter**

Upload `scripts/helpers/set-wallpaper.ps1` via SCP and run it to set solid gray wallpaper.

Disable clutter via registry/PowerShell:
- Widgets: `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` — `TaskbarDa`=0
- Notifications: `HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications` — `ToastEnabled`=0
- First-run experience / tips: `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` — set various `SubscribedContent-*` values to 0
- Search highlights: `HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings` — `IsDynamicSearchBoxEnabled`=0
- Windows Update auto-restart: configure active hours or disable auto-restart via group policy registry keys
- Cortana: `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search` — `AllowCortana`=0

- [ ] **Step 8: Reboot, verify, shutdown, and finalize golden**

Reboot via `shutdown /r /t 0`. Wait for SSH to come back on the `admin` account with key auth. Verify the desktop is clean (autologin worked, no popups).

Shut down via `shutdown /s /t 0`. Wait for QEMU process to exit. Stop swtpm.

The setup QCOW2, UEFI vars, and TPM state are now the golden image. Move/rename them to the golden paths in `~/.guivision/golden/`:
- `{name}.qcow2`
- `{name}-efivars.fd`
- `{name}-tpm/`

Delete any temporary files. Prevent the cleanup trap from deleting the golden.

- [ ] **Step 9: Make executable and commit**

`chmod +x scripts/vm-create-golden-windows.sh`
`git add scripts/vm-create-golden-windows.sh && git commit -m "feat: add Windows 11 ARM golden image creation script"`

---

### Task 5: Update vm-start.sh for multi-platform support

**Files:**
- Modify: `scripts/vm-start.sh`

- [ ] **Step 1: Add `--platform` argument and update defaults**

Add `--platform macos|linux|windows` option (default: `macos`). Set the default `_BASE` based on platform:
- `macos` → `guivision-golden-macos-tahoe`
- `linux` → `guivision-golden-linux-noble`
- `windows` → `guivision-golden-windows-11`

Add a `_TOOL` variable: `tart` for macOS/Linux, `qemu` for Windows.

- [ ] **Step 2: Add QEMU clone and boot logic**

For tart platforms, the existing clone/boot logic remains unchanged.

For Windows/QEMU, add:
- Clone: `qemu-img create -f qcow2 -b <golden>.qcow2 -F qcow2 <clone>.qcow2` in a temp directory. Also copy the UEFI vars and TPM state from the golden.
- Start swtpm for the clone's TPM state.
- Boot: launch `qemu-system-aarch64` with the same flags as the golden creation script but using the cloned disk/UEFI/TPM.
- VNC is at a known address (e.g. `localhost:5901`).
- SSH is at `localhost:2222` via port forwarding.

- [ ] **Step 3: Update VNC and SSH discovery**

For tart: existing logic (parse VNC URL from stdout, `tart ip` for SSH). No changes.

For QEMU: VNC host:port is known at launch time (from the `-vnc :N` flag). SSH is `localhost:2222`. No discovery needed.

- [ ] **Step 4: Update exported environment variables**

Rename all exports from `GUIVISION_TEST_*` to `GUIVISION_*`:
- `GUIVISION_VNC`, `GUIVISION_VNC_PASSWORD`, `GUIVISION_PLATFORM`, `GUIVISION_SSH`
- Keep `GUIVISION_VM_NAME`, `GUIVISION_VM_PID`
- Add `GUIVISION_VM_TOOL` (set to `tart` or `qemu`)

Update the platform value: `macos`, `linux`, or `windows` based on `--platform`.

For QEMU, `GUIVISION_SSH` should be `admin@localhost -p 2222`.

- [ ] **Step 5: Update the status output and header comment**

Update the comment block at the top of the file to document the new `--platform` option and the new env var names. Update the "VM ready" status output at the end to use the new var names.

- [ ] **Step 6: Update the existing-VM check for QEMU**

The current "stop existing VM" block uses `tart list` and `tart stop/delete`. For QEMU, check if a QEMU process is running for the same VM name (by PID file or process grep) and clean up the clone files.

- [ ] **Step 7: Commit**

`git add scripts/vm-start.sh && git commit -m "feat: multi-platform support in vm-start.sh"`

---

### Task 6: Update vm-stop.sh for multi-platform support

**Files:**
- Modify: `scripts/vm-stop.sh`

- [ ] **Step 1: Add QEMU teardown path**

Read `GUIVISION_VM_TOOL` to decide how to stop:
- `tart` (or unset, for backwards compat): existing `tart stop` + `tart delete` logic
- `qemu`: `kill $GUIVISION_VM_PID`, wait for exit, remove clone QCOW2 + UEFI vars + TPM state files. Also kill the associated swtpm process if running.

- [ ] **Step 2: Update env var unsets**

Change all `unset GUIVISION_TEST_*` to `unset GUIVISION_*`:
- `GUIVISION_VNC`, `GUIVISION_VNC_PASSWORD`, `GUIVISION_SSH`, `GUIVISION_PLATFORM`
- `GUIVISION_VM_NAME`, `GUIVISION_VM_PID`, `GUIVISION_VM_TOOL`
- Keep `GUIVISION_VM_VIEWER_WINDOW_ID` unset

- [ ] **Step 3: Update header comment**

Reflect the new behavior and env var names.

- [ ] **Step 4: Commit**

`git add scripts/vm-stop.sh && git commit -m "feat: multi-platform support in vm-stop.sh"`

---

### Task 7: Update test-integration.sh for multi-platform support

**Files:**
- Modify: `scripts/test-integration.sh`

- [ ] **Step 1: Add `--platform` argument and update defaults**

Same pattern as vm-start.sh: add `--platform macos|linux|windows` option (default: `macos`). Set `_BASE` and `_TOOL` based on platform. The default base names match vm-start.sh.

- [ ] **Step 2: Update golden image existence check**

For tart platforms: existing `tart list --format json` + grep check.
For Windows: check if the golden QCOW2 file exists at `~/.guivision/golden/$_BASE.qcow2`.

Update the "offer to create" prompt to call the platform-appropriate creation script: `scripts/vm-create-golden-macos.sh`, `scripts/vm-create-golden-linux.sh`, or `scripts/vm-create-golden-windows.sh`.

- [ ] **Step 3: Add QEMU clone/boot/discovery logic**

Same platform branching as vm-start.sh for clone, boot, VNC discovery, and SSH discovery. This script inlines the VM lifecycle (doesn't source vm-start.sh) so the same QEMU logic from Task 5 needs to be replicated here.

- [ ] **Step 4: Update cleanup trap for QEMU**

The cleanup function currently uses `tart stop` + `tart delete`. Add a branch on `_TOOL`:
- `tart`: existing logic
- `qemu`: kill QEMU process, kill swtpm, remove clone files

- [ ] **Step 5: Update exported environment variables**

Same rename as vm-start.sh: `GUIVISION_TEST_*` → `GUIVISION_*`. Add `GUIVISION_VM_TOOL`.

- [ ] **Step 6: Update header comment and `--keep` output**

Update the comment block for new options and env var names. Update the `--keep` message in the cleanup function to show the correct stop commands for the current platform.

- [ ] **Step 7: Commit**

`git add scripts/test-integration.sh && git commit -m "feat: multi-platform support in test-integration.sh"`

---

### Task 8: Update Swift integration tests for env var rename

**Files:**
- Modify: `Tests/IntegrationTests/VNCIntegrationTests.swift`

- [ ] **Step 1: Update TestEnv to read new env var names**

Change all `ProcessInfo.processInfo.environment["GUIVISION_TEST_*"]` reads to `GUIVISION_*`:
- `GUIVISION_TEST_VNC` → `GUIVISION_VNC`
- `GUIVISION_TEST_VNC_PASSWORD` → `GUIVISION_VNC_PASSWORD`
- `GUIVISION_TEST_SSH` → `GUIVISION_SSH`
- `GUIVISION_TEST_PLATFORM` → `GUIVISION_PLATFORM`

- [ ] **Step 2: Update the @Suite `.enabled(if:)` conditions**

The VNC suite checks `GUIVISION_TEST_VNC != nil` and the SSH suite checks `GUIVISION_TEST_SSH != nil`. Update both to use the new names.

- [ ] **Step 3: Update the comment block**

The `TestEnv` enum has a documentation comment listing the env vars and example usage. Update to reflect the new names.

- [ ] **Step 4: Verify it compiles**

Run: `swift build --filter IntegrationTests 2>&1 | tail -5`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

`git add Tests/IntegrationTests/VNCIntegrationTests.swift && git commit -m "refactor: rename GUIVISION_TEST_* env vars to GUIVISION_*"`

---

### Task 9: Update references in README and LLM_INSTRUCTIONS

**Files:**
- Modify: `README.md`
- Modify: `LLM_INSTRUCTIONS.md`

- [ ] **Step 1: Search for stale references**

Grep for `GUIVISION_TEST_`, `vm-create-golden.sh` (without platform suffix), `guivision-golden-tahoe` (without `macos-` prefix), and `testanyware` (legacy project name in comments) across all files.

- [ ] **Step 2: Update all references**

Update any occurrences found to use the new names:
- `vm-create-golden.sh` → `vm-create-golden-macos.sh`
- `GUIVISION_TEST_*` → `GUIVISION_*`
- `guivision-golden-tahoe` → `guivision-golden-macos-tahoe`
- `testanyware-*` → `guivision-*` (legacy project name in comments)

Add brief mentions of the Linux and Windows golden image scripts if appropriate.

- [ ] **Step 3: Commit**

`git add README.md LLM_INSTRUCTIONS.md && git commit -m "docs: update references for multi-platform golden images"`
