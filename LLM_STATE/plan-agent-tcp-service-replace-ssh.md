# Task: Convert Agents to TCP Services, Replace SSH

Convert all three platform agents (macOS, Windows, Linux) from one-shot SSH-exec CLIs
to persistent TCP services that fully replace SSH as the host-to-guest communication
channel. Install them as OS services in golden images. Eliminate SSH as a runtime
dependency (and from the Windows golden image entirely). Simultaneously simplify the
host codebase by removing SSH from the Swift library, removing OCR from the library,
and adopting Hummingbird for HTTP serving.

## Session Continuation Prompt

```
You MUST first read `LLM_CONTEXT/index.md` and `LLM_CONTEXT/coding-style.md`.

Continue working on the task outlined in `LLM_STATE/plan-agent-tcp-service-replace-ssh.md`.
Review the file to see current progress, then continue from the next incomplete step.
After completing each step, update the plan file with:
1. Mark the step as complete [x]
2. Add any learnings discovered

Use subagents (dispatching-parallel-agents) to parallelize independent work within
each session. Each session ends at an explicit STOP POINT — pause there for the user
to start a new session.

Key constraints:
- Do NOT include code in this plan document — describe what to do, not how
- Each agent is a server-only binary — no one-shot CLI mode. The binary starts,
  listens on port 8648, and stays running until killed or `/shutdown` is called.
- Use Hummingbird (Swift HTTP framework on SwiftNIO) for both the macOS agent and
  GUIVisionServer. Use URLSession for the host-side agent TCP client.
- Use ASP.NET Core minimal API for the Windows agent HTTP server.
- Use Python http.server for the Linux agent HTTP server.
- Golden image builds can be run and validated via VNC/QEMU — you have full access.
- macOS/Linux keep SSH for golden image CREATION (shell scripts) but not in the
  Swift library or runtime state.
- Windows eliminates SSH entirely — agent binary goes on the FAT16 autounattend media.
```

## Architecture Summary

After this work, the system has two independent channels:

```
Host CLI                              Guest VM
────────                              ────────
VNC channel (visual):                 VNC server (hypervisor)
  screenshots, input,                   framebuffer, RFB events
  video recording
  GUIVisionServer (connection cache)

Agent channel (semantic + exec):      guivision-agent (TCP service)
  accessibility tree, actions,          port 8648, HTTP/1.1 JSON
  exec, upload, download, shutdown
  AgentTCPClient (URLSession)
```

No SSH in the Swift library. No SSH in the runtime. SSH exists only in shell scripts
for golden image creation (macOS/Linux). VNC is the bootstrap/fallback channel (works
during boot, recovery mode, agent crash). Agent is the primary runtime channel.

## Simplifications Applied

**Host codebase:**
1. **Delete SSHClient, SSHSpec, SSH-based AgentClient from Swift library** — ~600 lines removed, zero functionality lost
2. **Delete OCR from library and server** — TextRecognizer, /ocr endpoint, ServerClient.ocr() removed; find-text stays as a standalone CLI command (used by golden image recovery boot scripts) that calls VNCCapture + Vision directly
3. **GUIVisionServer becomes VNC-only** — no SSH proxying, no OCR; just connection caching for VNC operations
4. **Agent commands go direct** — CLI → URLSession → agent TCP, not through GUIVisionServer
5. **ConnectionSpec = VNC + Agent** — no SSHSpec; simpler model
6. **Hummingbird replaces hand-rolled HTTPParser** — used by both macOS agent and GUIVisionServer; deletes HTTPParser.swift and all socket management code
7. **URLSession replaces hand-rolled TCP client** — AgentTCPClient uses Foundation, not custom socket code
8. **Rename `guivision ssh` → `guivision exec`/`upload`/`download`** — top-level commands, route through agent

**Golden images:**
9. **macOS: eliminate one boot cycle** — combine initial setup + agent install into a single boot instead of rebooting between them (saves ~2 min)
10. **macOS: keep Homebrew + Xcode CLI tools** — tests need Homebrew to install runtimes (Racket, Haskell, etc.), and Homebrew needs Xcode CLI tools to compile formulae.
11. **Windows: install Chocolatey** — tests need a package manager for runtimes (Racket, Haskell, OCaml, SWI-Prolog, jq, curl, etc.). Chocolatey has broad coverage and installs via a single PowerShell command during SetupComplete. Linux already has apt.
12. **Windows: consolidate to one install path** — the project has both autounattend.xml (Windows Setup) and install-windows.cmd (DISM bypass); pick one canonical path and remove the other
13. **Windows: entire SSH layer removed** — no OpenSSH Server install, no SSH key setup, no SSH_ASKPASS; massive reduction in script complexity

## Progress

### Session 1: Simplify Host Codebase + macOS Agent as Server

This session does two parallel tracks: simplifying the host library and converting the macOS agent.

- [x] 1.1 Add Hummingbird dependency to Package.swift
  - Add `hummingbird` package dependency (latest stable v2)
  - Both `guivision-agent` and `GUIVisionVMDriver` targets depend on it

- [x] 1.2 Convert GUIVisionServer from hand-rolled sockets to Hummingbird
  - Replace the entire socket creation, accept loop, read/write threading, and HTTPParser usage with a Hummingbird application
  - GUIVisionServer becomes a Hummingbird app listening on a Unix domain socket
  - Keep all existing VNC route handlers (health, screen-size, screenshot, input/*, record/*, stop)
  - Remove all `/ssh/*` route handlers (exec, upload, download) — these go through the agent now
  - Remove the `/ocr` route handler — OCR moves out of the server
  - Delete `HTTPParser.swift` — Hummingbird handles HTTP parsing

- [x] 1.3 Update ServerClient for Hummingbird compatibility
  - ServerClient still connects to the Unix domain socket, but the HTTP format is now Hummingbird's (standard HTTP/1.1 — should be compatible)
  - Remove `sshExec`, `sshUpload`, `sshDownload` methods
  - Remove `ocr` method
  - The server auto-start mechanism (spawning `_server` subprocess) stays the same

- [x] 1.4 Delete SSH from the Swift library
  - Delete `Sources/GUIVisionVMDriver/SSH/SSHClient.swift`
  - Delete `Tests/GUIVisionVMDriverTests/SSH/SSHClientTests.swift`
  - Remove `SSHSpec` from `ConnectionSpec.swift`
  - Remove SSH-related parsing from `ConnectionSpec.from()` (the `--ssh` flag)
  - Delete `Sources/GUIVisionVMDriver/Agent/AgentClient.swift` (the SSH-based agent invoker)
  - Remove SSH-related tests from `ConnectionSpecTests.swift`
  - Remove `SSHResult` struct (or move/rename to an agent-client response type)

- [x] 1.5 Remove OCR from the library
  - Delete `Sources/GUIVisionVMDriver/VNC/TextRecognizer.swift`
  - Update `FindTextCommand.swift` to use VNCCapture + Vision framework directly (inline the OCR logic — it's a few lines of VNRecognizeTextRequest) instead of going through the server
  - The `find-text` CLI command stays functional — it's used by golden image recovery boot scripts
  - Remove the TextMatch type from the library if it was only used by TextRecognizer (or keep it if FindTextCommand still needs it)

- [x] 1.6 Add AgentSpec to ConnectionSpec and create AgentTCPClient
  - Add `AgentSpec` struct (host: String, port: Int) to ConnectionSpec
  - Add optional `agent: AgentSpec?` field to `ConnectionSpec`
  - Add `--agent host:port` flag to `ConnectionSpec.from()` and `ConnectionOptions`
  - Update `ConnectionOptions.resolve()` to read `GUIVISION_AGENT` env var
  - Create `AgentTCPClient` in `Sources/GUIVisionVMDriver/Agent/AgentTCPClient.swift`
  - AgentTCPClient uses `URLSession` for HTTP requests to the agent TCP service
  - Methods: health, snapshot, windows, inspect, press, setValue, focus, showMenu, windowFocus/Resize/Move/Close/Minimize, screenshotElement/Window/Region, wait, exec, upload, download, shutdown

- [x] 1.7 Update CLI commands to use AgentTCPClient
  - Update `AgentCommand.swift`: `makeAgent()` returns an AgentTCPClient using the `--agent` option
  - Replace `SSHCommand.swift` with top-level `ExecCommand`, `UploadCommand`, `DownloadCommand` that use AgentTCPClient
  - Register the new commands in `GUIVisionCLI.swift`, remove `SSHCommand`
  - Update `InputCommand.swift` to remove any SSH dependency (window-relative coordinate lookup goes through agent)

- [x] 1.8 Convert macOS guivision-agent from one-shot CLI to Hummingbird TCP server
  - Replace the ArgumentParser subcommand structure — the binary is now a Hummingbird HTTP server
  - On launch: start Hummingbird on `0.0.0.0:8648` (configurable via `--port`)
  - Route incoming HTTP requests to existing accessibility logic (TreeWalker, QueryResolver, ActionPerformer, WindowCapture)
  - Delete all old CLI subcommand files: HealthCommand.swift, WindowsCommand.swift, SnapshotCommand.swift, InspectCommand.swift, ActionCommands.swift, WindowManageCommands.swift, ScreenshotCommands.swift, WaitCommand.swift, QueryOptions.swift, WindowFilter.swift, JSONOutput.swift
  - The routing logic lives in a new file (e.g., AgentServer.swift) that registers Hummingbird routes

- [x] 1.9 Implement system endpoints in macOS agent
  - `/exec`: run shell command via `Process`, return JSON {exitCode, stdout, stderr}
  - `/upload`: accept {path, content (base64)}, write to filesystem
  - `/download`: accept {path}, return {content (base64)}
  - `/shutdown`: trigger `osascript -e 'tell app "System Events" to shut down'` or `shutdown -h now`, return success before halting

- [x] 1.10 Unit tests
  - Test AgentTCPClient request building and response parsing (mock HTTP responses)
  - Test ConnectionSpec parsing with `--agent` flag and `GUIVISION_AGENT` env var
  - Test macOS agent route handlers with mock accessibility data
  - Test exec, upload/download round-trip with temp files
  - Verify `swift build` compiles cleanly with no SSH references

**STOP POINT — Session 1 complete. Verify: `swift build` passes, unit tests pass, `guivision-agent` starts and responds to `curl http://localhost:8648/health`, `guivision agent snapshot --agent localhost:8648` works, `guivision exec --agent localhost:8648 "uname -a"` works.**

### Code Review 1

- [x] 1.R Review Session 1 changes
  - Verify no SSH references remain in Swift source (grep for SSHClient, SSHSpec, ssh) ✓
  - Verify no OCR references remain in library (TextRecognizer, /ocr) ✓
  - Verify Hummingbird is used correctly in both GUIVisionServer and macOS agent ✓
  - Verify URLSession-based AgentTCPClient handles errors gracefully (connection refused, timeout) ✓
  - Verify find-text still works standalone (VNCCapture + Vision directly) ✓
  - Check the agent binds 0.0.0.0 (not localhost) since the host connects via port forwarding/bridge ✓
  - Fixed: stale "VNC + SSH" comment in GUIVisionVMDriver.swift → "VNC + Agent"

### Session 2: macOS Golden Image + vm-start.sh

- [x] 2.1 Create launchd plist for guivision-agent
  - Plist runs guivision-agent as a LaunchAgent (user-level, desktop session)
  - Key settings: RunAtLoad, KeepAlive, ProcessType=Interactive, stdout/stderr log paths, ThrottleInterval=5
  - File lives in project at `scripts/helpers/com.linkuistics.guivision.agent.plist`

- [x] 2.2 Simplify vm-create-golden-macos.sh
  - **Eliminated one boot cycle:** combined initial setup + agent install into a single boot
  - Agent binary + launchd plist installed in boot 1 alongside SSH key, wallpaper, CLT, Homebrew
  - After the SIP cycle + TCC grant, verifies agent health on port 8648 via curl
  - Revised boot sequence: 3 normal + 2 recovery = 5 boots (down from 4 normal + 2 recovery = 6)
  - Updated script header comment to document new boot sequence

- [x] 2.3 Update vm-start.sh
  - **All platforms:** after boot, polls for agent port 8648 readiness, exports `GUIVISION_AGENT`
  - **tart (macOS/Linux):** agent at `<vm-ip>:8648`, SSH kept as debug convenience
  - **QEMU (Windows):** port forwarding changed from `hostfwd=tcp::2222-:22` to `hostfwd=tcp::8648-:8648`
  - **Windows:** removed SSH port forwarding, SSH_ASKPASS, SSH wait loop, GUIVISION_SSH export
  - **macOS/Linux:** kept `GUIVISION_SSH` export as debugging convenience

- [x] 2.4 Build and validate macOS golden image (regression test)
  - Run `scripts/vm-create-golden-macos.sh` end-to-end
  - Start VM from the new golden image
  - Full validation checklist:
    - Agent health: `guivision agent health --agent <ip>:8648`
    - Accessibility: `guivision agent snapshot --agent <ip>:8648` returns populated tree
    - Exec: `guivision exec --agent <ip>:8648 "uname -a"` returns macOS info
    - TCC: `guivision exec --agent <ip>:8648 "sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' 'SELECT auth_value FROM access WHERE client=\"/usr/local/bin/guivision-agent\" AND service=\"kTCCServiceAccessibility\"'"` returns 2
    - SIP: `guivision exec --agent <ip>:8648 "csrutil status"` shows enabled
    - VNC screenshot: take screenshot, verify clean desktop (gray wallpaper, no widgets/dialogs)
    - Upload/download: round-trip a test file

**STOP POINT — Session 2 complete. Golden image builds, agent starts on boot via launchd, all validation checks pass.**

### Code Review 2

- [ ] 2.R Review Session 2 changes
  - Verify launchd plist is correct (ProcessType, resource limits, crash recovery)
  - Verify agent TCC accessibility works when launched via launchd (proven: snapshot returns windows)
  - Verify vm-start.sh handles agent-not-available gracefully for platforms without golden images yet
  - Verify resolveAgent() works with --agent only (no --vnc required)

### Session 3: Windows Agent — C# TCP Service

- [ ] 3.1 Create C# project structure
  - New directory: `agents/windows/` with a .NET 8+ project
  - Target: ARM64, self-contained single-file publish
  - Use ASP.NET Core minimal API for the HTTP server (built into .NET SDK, zero external deps for HTTP)
  - Add FlaUI.Core + FlaUI.UIA3 NuGet packages for UI Automation
  - The project produces `guivision-agent.exe`

- [ ] 3.2 Implement HTTP service with ASP.NET minimal API
  - Map all endpoints matching the macOS agent's protocol exactly
  - `/health`, `/exec`, `/upload`, `/download`, `/shutdown`
  - `/exec`: run commands via `Process.Start` with cmd.exe or powershell, capture output
  - `/shutdown`: `shutdown /s /t 0`
  - Listen on `http://0.0.0.0:8648`

- [ ] 3.3 Implement UI Automation accessibility commands
  - `/windows`, `/snapshot`, `/inspect`: walk UIA tree via FlaUI
  - `/press`, `/set-value`, `/focus`, `/show-menu`: UIA patterns (InvokePattern, ValuePattern, etc.)
  - `/window-*`: UIA WindowPattern/TransformPattern
  - `/screenshot-*`: screen capture scoped to elements/windows
  - `/wait`: poll for UIA tree changes

- [ ] 3.4 UIA ControlType to UnifiedRole mapping
  - Map all UIA control types to UnifiedRole vocabulary
  - Unmapped types → `unknown` with platformRole populated

- [ ] 3.5 Build and test Windows agent
  - Cross-compile: `dotnet publish -r win-arm64 --self-contained -p:PublishSingleFile=true`
  - If cross-compilation fails, build inside a Windows VM via the existing SSH-based golden image
  - Verify binary starts and responds to `/health` when run manually in a Windows VM desktop session

**STOP POINT — Session 3 complete. Verify: Windows agent binary exists, starts, responds to `/health`, UI Automation commands return valid data in a desktop session.**

### Code Review 3

- [ ] 3.R Review Session 3 changes
  - Verify agent runs in interactive desktop session (session 1), NOT session 0
  - Verify JSON response format matches macOS agent exactly
  - Verify exec handles both cmd.exe and PowerShell
  - Check binary size and startup time

### Session 4: Windows Golden Image — SSH-Free

- [ ] 4.1 Consolidate Windows install path
  - Currently there are two install mechanisms: `autounattend.xml` (Windows Setup) and `install-windows.cmd` (DISM bypass). Determine which one is actually used and remove the other.
  - If `autounattend.xml` handles partitioning + image installation correctly for ARM64, `install-windows.cmd` is dead code — delete it.
  - Similarly, `unattend-oobe.xml` may overlap with the oobeSystem section of `autounattend.xml` — consolidate.

- [ ] 4.2 Update autounattend media to include agent binary
  - Add compiled `guivision-agent.exe` to the FAT16 autounattend disk image
  - Increase FAT16 image size if needed (self-contained .NET binary may be 50-80MB; if too large for FAT16, use FAT32 or a separate small QCOW2 data disk)
  - Binary is copied from host build output during `vm-create-golden-windows.sh`

- [ ] 4.3 Move ALL post-install configuration into SetupComplete.cmd / autounattend.xml
  - SetupComplete.cmd handles everything that currently uses SSH:
    - Copy agent binary from autounattend drive to `C:\guivision\guivision-agent.exe`
    - Register as Task Scheduler logon task (NOT a Windows Service — session 0 has no desktop)
    - Configure firewall rule for port 8648
    - Start the agent
    - Apply all registry tweaks: wallpaper (solid gray), Cortana off, notifications off, taskbar widgets off, search box off, content delivery off, Windows Update set to manual
    - Install Chocolatey (single PowerShell command, no Store dependency) — tests need a package manager for runtimes (Racket, Haskell, OCaml, SWI-Prolog, jq, curl, etc.)
  - Remove ALL OpenSSH from autounattend.xml specialize pass, unattend-oobe.xml, and any SetupComplete.cmd
  - Remove SSH key installation, firewall rule for port 22

- [ ] 4.4 Update vm-create-golden-windows.sh
  - Remove ALL `vm_ssh` and `vm_scp` calls
  - Remove SSH_ASKPASS setup, SSH key installation, SSH verification
  - Remove SSH key dependency (script no longer needs `~/.ssh/id_ed25519.pub`)
  - Add QEMU port forwarding: `hostfwd=tcp::8648-:8648` (replace `hostfwd=tcp::2222-:22`)
  - Replace "Waiting for SSH" with "Waiting for agent": poll `localhost:8648/health`
  - Verification and shutdown all through agent endpoints
  - Build the C# agent binary before creating the autounattend media
  - The script should now be dramatically shorter — just: create disk, create autounattend media (with agent), boot QEMU, wait for agent, verify, shutdown, save

- [ ] 4.5 Build and validate Windows golden image (regression test)
  - Run `scripts/vm-create-golden-windows.sh --iso <path>` end-to-end
  - Monitor via VNC during install to confirm unattended progress
  - Start VM from the new golden image
  - Full validation checklist:
    - Agent health: `guivision agent health --agent localhost:8648`
    - Accessibility: `guivision agent snapshot --agent localhost:8648` returns populated UIA tree
    - Exec: `guivision exec --agent localhost:8648 "hostname"` returns GUIVISION
    - No SSH: `guivision exec --agent localhost:8648 "netstat -an | findstr :22"` shows no listeners
    - VNC screenshot: clean desktop (gray wallpaper, no Cortana, no widgets)
    - Upload/download: round-trip test file
    - Registry: verify all desktop clutter settings applied via agent exec

**STOP POINT — Session 4 complete. Verify: Windows golden image builds with zero SSH, agent starts on logon, full validation checklist passes.**

### Code Review 4

- [ ] 4.R Review Session 4 changes
  - Verify agent runs in interactive desktop session via Task Scheduler (not session 0)
  - Verify all SSH-related code is gone from Windows scripts and autounattend files
  - Verify the install path consolidation didn't break anything (only one of autounattend.xml / install-windows.cmd / unattend-oobe.xml set remains)
  - Verify FAT16/FAT32 image size accommodates the agent binary
  - Verify QEMU port forwarding is correct
  - Compare script line count before vs after — should be significantly shorter

### Session 5: Linux Agent — Python TCP Service + Golden Image

- [ ] 5.1 Create Python agent project
  - New directory: `agents/linux/`
  - Package: `guivision_agent/` with `__main__.py` entry point
  - HTTP server via Python `http.server` (stdlib, zero pip deps)
  - AT-SPI2 via `pyatspi2` (ships with Ubuntu Desktop)
  - Starts server on `0.0.0.0:8648` by default, `--port` to override

- [ ] 5.2 Implement HTTP service + system commands
  - Same endpoint set as macOS and Windows agents
  - `/exec`: `subprocess.run()`, capture output
  - `/upload`, `/download`: file I/O with base64
  - `/shutdown`: `subprocess.run(["sudo", "shutdown", "-h", "now"])`

- [ ] 5.3 Implement AT-SPI2 accessibility commands
  - `/windows`, `/snapshot`, `/inspect`: walk AT-SPI2 tree
  - `/press`, `/set-value`, `/focus`, `/show-menu`: AT-SPI2 action/value interfaces
  - `/window-*`: AT-SPI2 or wmctrl/xdotool fallback
  - `/screenshot-*`: screen capture via platform APIs
  - `/wait`: poll for AT-SPI2 tree changes

- [ ] 5.4 ATK Role to UnifiedRole mapping
  - Map pyatspi2 role constants to UnifiedRole vocabulary

- [ ] 5.5 Update vm-create-golden-linux.sh
  - SCP Python agent package into VM during golden image creation
  - Install to `/opt/guivision/`
  - Create systemd user service (runs in admin user's desktop session via autologin)
  - Enable AT-SPI2: `gsettings set org.gnome.desktop.interface toolkit-accessibility true`
  - After reboot, verify agent health on port 8648

- [ ] 5.6 Build and validate Linux golden image (regression test)
  - Run `scripts/vm-create-golden-linux.sh` end-to-end
  - Start VM from the new golden image
  - Full validation checklist:
    - Agent health: `guivision agent health --agent <ip>:8648`
    - Accessibility: `guivision agent snapshot --agent <ip>:8648` returns populated AT-SPI2 tree
    - Exec: `guivision exec --agent <ip>:8648 "uname -a"` returns Linux info
    - VNC screenshot: clean desktop (gray wallpaper, no notifications, GDM autologin worked)
    - Upload/download: round-trip test file
    - AT-SPI2: tree contains GNOME desktop elements (panel, activities, etc.)

**STOP POINT — Session 5 complete. Verify: Linux golden image builds, agent starts on boot, full validation checklist passes.**

### Code Review 5

- [ ] 5.R Review Session 5 changes
  - Verify AT-SPI2 works under Wayland (Ubuntu 24.04 default)
  - Verify systemd user service starts after desktop session is fully loaded
  - Verify zero pip install required at runtime (pyatspi2 ships with Ubuntu Desktop)
  - Check role mapping for GNOME desktop elements

### Session 6: Documentation + Final Validation

- [ ] 6.1 Update the agent design spec
  - Update `docs/superpowers/specs/2026-04-04-in-vm-accessibility-agent-design.md`
  - Architecture: agents are TCP servers on port 8648, not one-shot CLIs
  - Connectivity: agent TCP replaces SSH exec; two-channel model (VNC visual + agent semantic)
  - Add exec/upload/download/shutdown to endpoint table
  - Update golden image sections for all three platforms
  - Remove "Future Platforms" — they're all implemented now

- [ ] 6.2 Update README.md
  - Architecture overview: two-channel model
  - Connection: `--vnc host:port --agent host:port` (no `--ssh`)
  - Environment: `GUIVISION_AGENT` replaces `GUIVISION_SSH`
  - Golden images: SSH-free Windows, agent-primary macOS/Linux
  - CLI commands: `exec`/`upload`/`download` replace `ssh exec`/`upload`/`download`

- [ ] 6.3 Update LLM_INSTRUCTIONS.md
  - Update command reference for agent-based usage
  - Remove SSH references from connection options

- [ ] 6.4 Final integration test — all three platforms
  - Build all three golden images (parallelizable with subagents)
  - Start one VM of each platform
  - For each: verify health, snapshot, press, exec, upload/download, screenshot through agent TCP
  - Verify Windows has no SSH
  - Verify macOS and Linux work through agent TCP

**STOP POINT — Session 6 complete. All documentation updated, all golden images validated, SSH eliminated from runtime.**

## Learnings

### Session 1

1. **Hummingbird v2.21.1** resolved cleanly with Swift 6.3. The `swift-tools-version: 6.0` in Package.swift doesn't need bumping — SPM resolves deps independently.

2. **Name collision**: Custom `HTTPRequest`/`HTTPResponse` types in ServerClient.swift collide with `HTTPTypes.HTTPRequest`/`HTTPResponse` from Hummingbird. Renamed to `WireRequest`/`WireResponse` for the client-side Unix domain socket wire protocol.

3. **Actor + Hummingbird route closures**: Route handler closures capture the actor `self` and `await` actor-isolated methods. This works cleanly in Swift 6 since actors are Sendable. The pattern is `router.get("/path") { [server] _, _ in await server.handleFoo() }`.

4. **Router is not Sendable**: `Router<BasicRequestContext>` cannot be returned from an actor-isolated method across isolation boundaries. Tests must call handler methods directly on the actor rather than building a router and using HummingbirdTesting.

5. **ServerClient wire protocol preserved**: The raw BSD socket + HTTP/1.1 wire protocol between ServerClient and GUIVisionServer is preserved — just the server-side HTTP parsing moved from custom HTTPParser to Hummingbird. The client still serializes manually over UDS.

6. **FindTextCommand OCR inlining**: Rather than managing its own VNC connection, FindTextCommand calls `ServerClient.screenshot()` (which uses the server's VNC cache) and runs Vision OCR locally. TextMatch type moved into FindTextCommand.

7. **guivision-agent uses `main.swift`** (not `@main` struct) since it removed ArgumentParser — the entry point is top-level async code that creates and runs the Hummingbird Application.

8. **AgentFormatter gained typed overloads**: Added `formatSnapshot(_ response:)`, `formatAction(_ response:)`, etc. alongside the existing `formatSnapshot(_ data:)` methods. The data-based methods now delegate to the typed versions.

### Session 2

1. **LaunchAgent not LaunchDaemon**: The agent must run as a user-level LaunchAgent (`~/Library/LaunchAgents/`) to access the desktop session's accessibility APIs. LaunchDaemons run in session 0 (root) with no GUI. `ProcessType=Interactive` ensures proper scheduling for a UI-interacting agent.

2. **`defaults write` doesn't need a reboot**: The old script rebooted between "config" and "agent install" because someone assumed loginwindow needs a reboot to pick up `defaults write` changes. In reality, `defaults write` modifies plist files read on-demand — the changes take effect when processes next read them, which happens naturally on the recovery-cycle's normal reboot.

3. **Agent health check via SSH+curl**: During golden image creation, the agent health is verified by running `curl -sf http://localhost:8648/health` over SSH inside the VM. This confirms both that launchd started the agent and that it's responding on the expected port.

4. **Windows SSH fully removed from vm-start.sh**: QEMU port forwarding changed from `hostfwd=tcp::2222-:22` to `hostfwd=tcp::8648-:8648`. All SSH_ASKPASS, SSH wait loops, and GUIVISION_SSH export removed for the Windows path. macOS/Linux keep SSH as a debug convenience only.

5. **Stale comment in GUIVisionVMDriver.swift**: Module-level comment still said "VNC + SSH driver" — updated to "VNC + Agent driver" during code review 1.

6. **`resolveAgent()` required `--vnc`**: The CLI's `resolveAgent()` method called `resolve()` which required `--vnc`. Fixed to check `--agent` and `GUIVISION_AGENT` env var directly before falling back to the full connection spec. Agent-only commands now work without `--vnc`.
