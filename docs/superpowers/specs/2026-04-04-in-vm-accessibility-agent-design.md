# In-VM Accessibility Agent — Design Spec

## Overview

An accessibility agent that runs inside guest VMs (macOS, Windows, Linux) as a one-shot CLI tool, invoked via SSH from the host `guivision` CLI. Each invocation captures accessibility state, performs an action, or inspects elements, then exits. This enables LLM-driven GUI application development, testing, and visual verification with minimal infrastructure.

## Goals

- Enable LLMs to discover, inspect, and interact with UI elements semantically (by role, label, query) rather than by pixel coordinates alone
- Support visual verification of GUI properties (layout, spacing, fonts, colors) for TDD workflows
- Provide a unified CLI interface across macOS, Windows, and Linux — the host CLI doesn't need to know which platform the agent runs on
- Cover desktop applications, web content in browsers (Chrome, Safari, Firefox), and transient UI (menus, toasts, popups)
- Optimize for LLM token efficiency and ease of reasoning

## Architecture

### System Layers

```
LLM
 |  (shell commands)
 v
guivision CLI  (host — new `agent` subcommand group)
 |  (SSH exec)
 v
guivision-agent  (inside VM — one-shot CLI, platform-specific binary)
 |  (native API)
 v
Platform Accessibility API  (AXUIElement / UI Automation / AT-SPI2)
```

### Design Principles

- **One-shot execution:** Each invocation is stateless — the agent starts, performs one operation, outputs JSON to stdout, and exits. No daemon, no port, no persistent state.
- **Smart agent, smart CLI:** The agent handles atomic accessibility operations (snapshot, find-and-act, inspect) and returns structured JSON. The host CLI formats JSON into concise, LLM-optimized text output. The agent owns "what's on screen"; the CLI owns "how to present it."
- **Query-based targeting:** Elements are targeted by query (role, label, window, accessibility ID) rather than by persistent refs. Each invocation resolves the query fresh against the current UI state. This eliminates stale refs and race conditions.
- **Two observation channels:** Structured data (a11y tree) for element discovery, state, and layout. Visual data (screenshots) for colors, borders, styles — properties only pixels can reveal.
- **Unified interface:** The agent CLI contract (subcommands, arguments, JSON output schema) is identical across all three platforms. Each platform agent maps its native accessibility concepts to the shared schema.

### Connectivity

The host CLI invokes the agent via SSH exec through the existing `SSHClient`:

```
ssh user@vm /usr/local/bin/guivision-agent snapshot --mode interact --window "Settings"
```

- No ports, no tunnels, no daemon lifecycle
- Leverages the existing SSH multiplexed connection for performance
- The agent binary just needs to exist at a known path on the VM
- Consistent across all three platforms

### Element Targeting

Since the agent is stateless (no persistent refs), elements are targeted by query. The agent resolves the query against the current UI state on each invocation.

**Query parameters** (used across action and inspection commands):

| Parameter | Description |
|-----------|-------------|
| `--role ROLE` | Match by unified role (e.g., `button`, `textfield`) |
| `--label TEXT` | Match by label substring |
| `--id ID` | Match by developer-assigned accessibility ID (when available) |
| `--window FILTER` | Scope to a window by title substring or app name |
| `--index N` | Disambiguate when multiple elements match (1-based) |

**Disambiguation:** If a query matches multiple elements, the agent returns all matches with enough context (role, label, position, window) for the LLM to refine using `--index` or a more specific query.

**Combined find-and-act:** Actions resolve the target and perform the action in a single invocation — no separate "find" step needed:

```
guivision agent press --role button --label "Save" --window "Settings"
guivision agent set-value --role textfield --label "Name" --value "hello"
```

## Unified Element Model

Every UI element is represented with a platform-agnostic schema.

### Element Fields

| Field | Type | Description |
|-------|------|-------------|
| `role` | string | Normalized role from the unified vocabulary |
| `label` | string? | Visible or accessibility label |
| `value` | string? | Current value for stateful elements |
| `description` | string? | Accessibility description/help text if distinct from label |
| `id` | string? | Developer-assigned accessibility identifier (if present) |
| `enabled` | bool | Whether the element accepts interaction |
| `focused` | bool | Whether the element has keyboard focus |
| `position` | `{x, y}` | Position relative to containing window (top-left corner) |
| `size` | `{w, h}` | Width and height |
| `children` | int | Count of child elements (for on-demand expansion) |
| `actions` | [string] | Available actions: `press`, `confirm`, `cancel`, `increment`, `decrement`, `pick`, `show-menu`, etc. |
| `platformRole` | string? | Original platform-specific role (e.g., `AXPopUpButton`) — included when the unified role loses information |

### Role Vocabulary

The unified role vocabulary is based on the full AccessKit 182-role enum (derived from Chromium's cross-platform accessibility abstraction and WAI-ARIA). This covers:

- **Desktop widgets:** button, checkbox, radio, textfield, combobox, slider, switch, tab, tree, treeitem, splitbutton, disclosure-triangle, date-picker, etc.
- **Web/ARIA roles:** article, banner, complementary, contentinfo, form, main, navigation, region, etc.
- **Document roles:** heading, paragraph, blockquote, code, figure, list, table, etc.
- **Menus:** menubar, menu, menuitem, menuitemcheckbox, menuitemradio
- **Containers:** window, dialog, alert, group, toolbar, tabpanel, scrollarea, separator
- **Transient surfaces:** popover, tooltip, toast, notification

Each platform agent maintains a mapping table from its native roles to this canonical set. Unmapped native roles map to `unknown` with the `platformRole` field populated. The vocabulary is a shared artifact that grows as new unmapped roles are encountered.

### Window and Surface Model

The API distinguishes between:

- **Application windows** — main windows the user works with
- **Transient surfaces** — menus, popups, tooltips, dropdowns, dialogs, toasts — logically children of an interaction in another window

The `guivision agent windows` output includes both, with type annotations:

```
"My App - main.swift" (window) 800x600 [focused] app:"Xcode"
"Settings" (dialog) 400x300 app:"My App"
(menu) 200x150 app:"My App"
(popover) 180x90 app:"My App"
```

Transient surfaces appear and disappear as the UI changes. The LLM uses a snapshot-action-snapshot cycle: take a snapshot, perform an action that opens a menu/popup, take another snapshot to see the new content.

## Agent CLI Interface

The in-VM agent is a CLI tool with subcommands. It outputs JSON to stdout (formatted by the host CLI for LLM consumption) and returns exit code 0 on success, non-zero on error with a JSON error object on stderr.

### Subcommands

**Discovery & Inspection:**

| Subcommand | Purpose |
|------------|---------|
| `health` | Check agent status and accessibility permissions |
| `windows` | List all windows and transient surfaces |
| `snapshot` | Capture current a11y tree with filters |
| `inspect` | Detailed properties of a single element — font, bounds, style info |
| `screenshot-element` | Screenshot cropped to a matched element's bounds |
| `screenshot-window` | Screenshot of a specific window |
| `screenshot-region` | Screenshot of a window-relative region |

**Actions:**

| Subcommand | Purpose |
|------------|---------|
| `press` | Press/click a matched element |
| `set-value` | Set value on a matched element (text field, checkbox, slider) |
| `focus` | Move focus to a matched element |
| `show-menu` | Open menu/context menu on a matched element |

**Window Management:**

| Subcommand | Purpose |
|------------|---------|
| `window-focus` | Bring a window to front |
| `window-resize` | Resize a window |
| `window-move` | Move a window |
| `window-close` | Close a window |
| `window-minimize` | Minimize/restore a window |

### Snapshot Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `--mode` | string | `interact` (actionable elements, states), `layout` (all elements with position/size), `full` (everything including font info) |
| `--window` | string | Scope to a window by title substring or app name |
| `--role` | string | Filter by element role |
| `--label` | string | Filter by label substring |
| `--depth` | int | Tree depth, default 3 |

### CLI Output Format

The host CLI formats the agent's JSON responses as indented text optimized for LLM consumption:

```
"My App" (window) 800x600
  toolbar
    button "New" [enabled]
    button "Save" [enabled]
    button "Undo" [disabled]
  textfield "Search..." [focused] value=""
  group "Content"
    list "Items" 3 items
      listitem "First item" [selected]
      listitem "Second item"
      listitem "Third item"
```

Elements are identified by their role + label in context, not by refs. When the LLM needs to act on an element, it constructs a query from what it sees in the snapshot.

## Host CLI Integration

### New Subcommand Group: `guivision agent`

The host CLI translates its subcommands into SSH exec calls to the in-VM agent binary:

```
guivision agent snapshot [--mode interact|layout|full] [--window FILTER] [--role ROLE] [--label TEXT] [--depth N]
guivision agent inspect --role ROLE --label TEXT [--window FILTER]
guivision agent press --role ROLE --label TEXT [--window FILTER] [--index N]
guivision agent set-value --role ROLE --label TEXT --value TEXT [--window FILTER]
guivision agent focus --role ROLE --label TEXT [--window FILTER]
guivision agent show-menu --role ROLE --label TEXT [--window FILTER]
guivision agent windows
guivision agent window-focus --window FILTER
guivision agent window-resize --window FILTER --width W --height H
guivision agent window-move --window FILTER --x X --y Y
guivision agent window-close --window FILTER
guivision agent window-minimize --window FILTER
guivision agent screenshot-element --role ROLE --label TEXT [--window FILTER] [--padding N]
guivision agent screenshot-window --window FILTER
guivision agent wait [--timeout SECONDS]
```

### Window-Relative Coordinates on Existing Commands

The existing `guivision input` and `guivision screenshot` commands gain a `--window` parameter:

```
guivision input click --x 100 --y 50 --window "Settings"
guivision input move --x 200 --y 300 --window "Settings"
guivision screenshot --window "My App"
```

When `--window` is provided, the CLI queries the agent for the window's position and converts window-relative coordinates to absolute screen coordinates before sending through VNC.

### Error Handling

The agent is a required component. If the agent binary is not found, SSH exec fails, or accessibility permissions are not granted, the CLI raises an error immediately. There is no fallback or degraded mode.

## macOS Agent Implementation (Phase 1)

### Technology

- **Language:** Swift (consistent with the host CLI)
- **Accessibility API:** AXUIElement from ApplicationServices framework
- **Dependencies:** Foundation, ApplicationServices only — no third-party dependencies
- **Build:** Separate executable target in `Package.swift` alongside the existing `guivision` CLI
- **Bundle ID:** `com.linkuistics.guivision.agent`

### Process Model

- Standalone CLI executable: `guivision-agent`
- One-shot: invoked via SSH, performs one operation, outputs JSON to stdout, exits
- No daemon, no LaunchAgent, no network listener
- Installed at `/usr/local/bin/guivision-agent`

### Internal Architecture

- Argument parsing via swift-argument-parser (shared dependency with host CLI)
- Core accessibility layer wraps `AXUIElement` for tree walking, attribute queries, and actions
- Snapshot engine: walks the tree, applies filters (role, label, depth, window scope), serializes to JSON
- Query resolver: given targeting parameters (role, label, window, id, index), finds matching elements in the current tree
- Screenshot capture: uses `CGWindowListCreateImage` scoped to specific windows or regions

### Role Mapping

The macOS agent maps AXRole values to the unified vocabulary. Examples:

| macOS | Unified |
|-------|---------|
| AXButton | button |
| AXTextField | textfield |
| AXPopUpButton | combobox |
| AXMenu | menu |
| AXMenuItem | menuitem |
| AXGroup + AXApplicationDialog subrole | dialog |
| AXRadioButton (in AXTabGroup) | tab |
| AXSheet | dialog |
| AXStaticText | text |

The full mapping table is maintained in the agent source code and extended as unmapped roles are encountered.

## Golden Image Installation (macOS)

Added to `scripts/vm-create-golden-macos.sh` after existing setup steps. The process requires a multi-boot SIP disable/enable cycle to grant accessibility permissions without triggering consent alerts.

### Boot Sequence

1. **Normal boot** — existing setup: SSH keys, Homebrew, Xcode CLI tools, wallpaper, etc.
2. **Shutdown → Recovery boot** — disable SIP via `csrutil disable`
3. **Reboot to normal** — modify TCC database: insert accessibility permission for `com.linkuistics.guivision.agent`
4. **Shutdown → Recovery boot** — re-enable SIP via `csrutil enable`
5. **Reboot to normal** — install agent binary to `/usr/local/bin/guivision-agent`, verify with `guivision-agent health`
6. **Shutdown → clone to golden image**

### Why the SIP Cycle

Modifying the TCC database while SIP is enabled causes macOS to show permission alert dialogs, which pollute the screen display and break visual testing. This was learned from the prior TestAnyware project. Disabling SIP, making the TCC change, then re-enabling SIP avoids the alerts while maintaining a standard SIP-enabled test environment.

## The `wait` Command

Since the agent is one-shot and stateless, the `wait` command works by:

1. Taking an initial snapshot of the a11y tree (or a hash of it)
2. Polling at short intervals (e.g., 100ms) until the tree changes or the timeout expires
3. Returning success (tree changed) or timeout (no change detected)

This supports the snapshot-action-snapshot cycle for transient UI: the LLM performs an action (e.g., clicks a menu), calls `wait` to let the UI settle, then takes a fresh snapshot to see the new state.

The `wait` command accepts `--window FILTER` to scope change detection to a specific window, and `--timeout SECONDS` (default 5) to limit how long it polls.

## Future Platforms

### Windows (Phase 2)

- **Language:** C# with `dotnet publish -r win-arm64 --self-contained -p:PublishSingleFile=true`
- **Accessibility API:** UI Automation via FlaUI or System.Windows.Automation
- **Process:** One-shot CLI, invoked via SSH, same subcommand interface
- **Installation:** Cross-compiled from macOS, SCP'd into VM during golden image creation
- **Role mapping:** UIA control types (Button, Edit, ComboBox, etc.) → unified vocabulary

### Linux (Phase 3)

- **Language:** Python
- **Accessibility API:** AT-SPI2 via `pyatspi2` or D-Bus directly
- **Process:** One-shot CLI, invoked via SSH, same subcommand interface
- **Installation:** Python files SCP'd into VM, dependencies installed via pip
- **Prerequisite:** Verify AT-SPI2 accessibility bus is enabled during golden image creation
- **Role mapping:** ATK roles (ROLE_PUSH_BUTTON, ROLE_ENTRY, etc.) → unified vocabulary

## Prior Art & References

This design is informed by research into existing tools in the space:

- **Playwright MCP / FlaUI-MCP** — snapshot pattern, indented text output for LLM consumption
- **AccessKit** — unified role vocabulary derived from Chromium's cross-platform abstraction (182 roles)
- **UFO2 (Microsoft)** — hybrid a11y tree + vision approach, Set-of-Mark prompting
- **OSWorld benchmark** — screenshot + a11y tree yields best agent performance
- **Windows-Use** — a11y tree costs ~8k tokens vs ~50k for screenshots per 20-step workflow
- **W3C Core-AAM 1.2** — cross-platform role mapping reference (ARIA ↔ UIA ↔ ATK ↔ macOS)
- **Appium** — cross-platform automation server architecture
