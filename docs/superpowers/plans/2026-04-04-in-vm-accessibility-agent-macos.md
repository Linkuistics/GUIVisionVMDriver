# In-VM Accessibility Agent (macOS Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-shot CLI accessibility agent (`guivision-agent`) for macOS that runs inside VMs, invoked via SSH, with host CLI integration through new `guivision agent` subcommands.

**Architecture:** A Swift CLI executable using AXUIElement from ApplicationServices to walk the accessibility tree, query elements, and perform actions. A shared `GUIVisionAgentProtocol` library defines the unified role vocabulary and JSON models used by both the agent and the host CLI. The host CLI invokes the agent via `SSHClient.exec()` and formats the JSON output as LLM-optimized text.

**Tech Stack:** Swift 6.0, ApplicationServices (AXUIElement), swift-argument-parser, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-04-04-in-vm-accessibility-agent-design.md`

---

## File Structure

### New targets

**`GUIVisionAgentProtocol`** — shared library for models and role vocabulary:

| File | Responsibility |
|------|---------------|
| `Sources/GUIVisionAgentProtocol/UnifiedRole.swift` | Full AccessKit-derived role enum (~180 roles), Codable, CaseIterable |
| `Sources/GUIVisionAgentProtocol/ElementInfo.swift` | Platform-agnostic element model (role, label, value, position, size, states, actions, id, platformRole) |
| `Sources/GUIVisionAgentProtocol/WindowInfo.swift` | Window/surface model (title, type, size, position, app name, focused) |
| `Sources/GUIVisionAgentProtocol/AgentResponses.swift` | Response envelopes: SnapshotResponse, WindowsResponse, InspectResponse, ActionResponse, ErrorResponse |

**`guivision-agent`** — in-VM CLI executable:

| File | Responsibility |
|------|---------------|
| `Sources/guivision-agent/AgentCLI.swift` | Main entry point, top-level AsyncParsableCommand with subcommand registration |
| `Sources/guivision-agent/QueryOptions.swift` | Shared ParsableArguments for element targeting (--role, --label, --window, --id, --index) |
| `Sources/guivision-agent/WindowFilter.swift` | Shared ParsableArguments for window targeting (--window) |
| `Sources/guivision-agent/JSONOutput.swift` | Helper to encode any Encodable to stdout as JSON, and write errors to stderr |
| `Sources/guivision-agent/HealthCommand.swift` | Check accessibility permissions via AXIsProcessTrusted() |
| `Sources/guivision-agent/WindowsCommand.swift` | List all windows and transient surfaces |
| `Sources/guivision-agent/SnapshotCommand.swift` | Capture filtered a11y tree snapshot |
| `Sources/guivision-agent/InspectCommand.swift` | Detailed properties of a matched element |
| `Sources/guivision-agent/ActionCommands.swift` | press, set-value, focus, show-menu subcommands |
| `Sources/guivision-agent/WindowManageCommands.swift` | window-focus, window-resize, window-move, window-close, window-minimize |
| `Sources/guivision-agent/ScreenshotCommands.swift` | screenshot-element, screenshot-window, screenshot-region |
| `Sources/guivision-agent/WaitCommand.swift` | Poll for a11y tree changes with timeout |
| `Sources/guivision-agent/Accessibility/AccessibleElement.swift` | Protocol abstracting AXUIElement for testability |
| `Sources/guivision-agent/Accessibility/AXElementWrapper.swift` | Real implementation wrapping AXUIElement API |
| `Sources/guivision-agent/Accessibility/RoleMapper.swift` | Maps macOS AXRole/AXSubrole to UnifiedRole |
| `Sources/guivision-agent/Accessibility/TreeWalker.swift` | Recursive tree walking with depth/filter, converts to ElementInfo |
| `Sources/guivision-agent/Accessibility/QueryResolver.swift` | Finds elements matching query criteria, handles disambiguation |
| `Sources/guivision-agent/Accessibility/ActionPerformer.swift` | Performs AX actions (press, setValue, setFocus, showMenu) |
| `Sources/guivision-agent/Screenshot/WindowCapture.swift` | CGWindowListCreateImage wrapper for window/element/region capture |

### Modifications to existing targets

**`GUIVisionVMDriver`** library:

| File | Responsibility |
|------|---------------|
| `Sources/GUIVisionVMDriver/Agent/AgentClient.swift` | Invokes guivision-agent via SSHClient.exec(), parses JSON responses |

**`guivision`** CLI:

| File | Responsibility |
|------|---------------|
| `Sources/guivision/AgentCommand.swift` | New `agent` subcommand group, maps args to AgentClient calls |
| `Sources/guivision/AgentFormatter.swift` | Converts JSON responses to LLM-optimized indented text for stdout |

### New test targets

**`GUIVisionAgentProtocolTests`**:

| File | Responsibility |
|------|---------------|
| `Tests/GUIVisionAgentProtocolTests/UnifiedRoleTests.swift` | Role enum coding round-trip, rawValue stability |
| `Tests/GUIVisionAgentProtocolTests/ModelCodingTests.swift` | JSON encode/decode for all model types |

**`GUIVisionAgentTests`**:

| File | Responsibility |
|------|---------------|
| `Tests/GUIVisionAgentTests/RoleMapperTests.swift` | All known macOS AXRole → UnifiedRole mappings |
| `Tests/GUIVisionAgentTests/TreeWalkerTests.swift` | Tree walking with mock elements, depth/filter behavior |
| `Tests/GUIVisionAgentTests/QueryResolverTests.swift` | Query matching, disambiguation, index selection |
| `Tests/GUIVisionAgentTests/AgentFormatterTests.swift` | JSON → LLM text formatting for all response types |

**Existing test target additions** (`GUIVisionVMDriverTests`):

| File | Responsibility |
|------|---------------|
| `Tests/GUIVisionVMDriverTests/Agent/AgentClientTests.swift` | Command construction, JSON response parsing |

### Script modifications

| File | Change |
|------|--------|
| `scripts/vm-create-golden-macos.sh` | Add SIP disable/enable cycle, TCC modification, agent binary installation |

---

## Task 1: Project Scaffolding & Package Configuration

**Files:**
- Modify: `Package.swift`
- Create: `Sources/GUIVisionAgentProtocol/` (empty placeholder file)
- Create: `Sources/guivision-agent/` (empty placeholder file)
- Create: `Tests/GUIVisionAgentProtocolTests/` (empty placeholder file)
- Create: `Tests/GUIVisionAgentTests/` (empty placeholder file)

- [ ] **Step 1:** Add four new targets to `Package.swift`:
  - `GUIVisionAgentProtocol` library target at `Sources/GUIVisionAgentProtocol` with no dependencies
  - `guivision-agent` executable target at `Sources/guivision-agent` depending on `GUIVisionAgentProtocol` and `ArgumentParser`, with linker settings for `ApplicationServices` and `CoreGraphics` frameworks
  - `GUIVisionAgentProtocolTests` test target depending on `GUIVisionAgentProtocol`
  - `GUIVisionAgentTests` test target depending on `GUIVisionAgentProtocol` (and eventually the agent source, but for now just the protocol)
  - Add `GUIVisionAgentProtocol` as a dependency of the existing `guivision` target and `GUIVisionVMDriver` target
  - Add `.executable(name: "guivision-agent", targets: ["guivision-agent"])` to products

- [ ] **Step 2:** Create minimal placeholder source files so the package compiles:
  - `Sources/GUIVisionAgentProtocol/UnifiedRole.swift` — empty enum stub
  - `Sources/guivision-agent/AgentCLI.swift` — minimal `@main` AsyncParsableCommand
  - `Tests/GUIVisionAgentProtocolTests/PlaceholderTest.swift` — single passing test
  - `Tests/GUIVisionAgentTests/PlaceholderTest.swift` — single passing test

- [ ] **Step 3:** Verify the project builds and tests pass

  Run: `swift build 2>&1 | tail -5`
  Expected: Build succeeds with both `guivision` and `guivision-agent` executables

  Run: `swift test 2>&1 | tail -10`
  Expected: All tests pass (including the two new placeholder tests)

- [ ] **Step 4:** Commit

  `git commit -m "feat: add guivision-agent and GUIVisionAgentProtocol targets"`

---

## Task 2: Unified Role Vocabulary

**Files:**
- Create: `Sources/GUIVisionAgentProtocol/UnifiedRole.swift`
- Create: `Tests/GUIVisionAgentProtocolTests/UnifiedRoleTests.swift`

- [ ] **Step 1:** Write tests for UnifiedRole:
  - Test that the enum is Codable: encode a role to JSON string, decode it back, verify round-trip
  - Test multiple roles (button, textfield, window, dialog, menuitem, unknown) to confirm raw values are stable lowercase strings
  - Test that `unknown` role exists as a catch-all
  - Test CaseIterable conformance (count should match expected number of roles)

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentProtocolTests 2>&1 | tail -5`
  Expected: Compilation fails (enum not yet defined)

- [ ] **Step 3:** Implement `UnifiedRole` enum
  - String-backed enum (`RawRepresentable` with String raw values)
  - Conforming to `Codable`, `Sendable`, `CaseIterable`, `Equatable`
  - Include the full AccessKit-derived role set organized into groups: interactive widgets, menus, containers/structure, content, transient surfaces, web/ARIA, document, and `unknown`
  - Reference AccessKit's Role enum at `https://docs.rs/accesskit/latest/accesskit/enum.Role.html` for the complete list
  - Use lowercase-hyphenated raw values (e.g., `splitButton` case with raw value `"split-button"`)

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentProtocolTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Commit

  `git commit -m "feat: add UnifiedRole enum with AccessKit-derived role vocabulary"`

---

## Task 3: Shared Agent Models

**Files:**
- Create: `Sources/GUIVisionAgentProtocol/ElementInfo.swift`
- Create: `Sources/GUIVisionAgentProtocol/WindowInfo.swift`
- Create: `Sources/GUIVisionAgentProtocol/AgentResponses.swift`
- Create: `Tests/GUIVisionAgentProtocolTests/ModelCodingTests.swift`
- Delete: `Tests/GUIVisionAgentProtocolTests/PlaceholderTest.swift`

- [ ] **Step 1:** Write tests for model JSON round-trips:
  - `ElementInfo`: create an element with all fields populated, encode to JSON, decode, verify equality. Also test with optional fields nil.
  - `WindowInfo`: same pattern — with title, without title (for transient surfaces like menus)
  - `SnapshotResponse`: containing a list of WindowInfo each with nested ElementInfo trees
  - `ActionResponse`: success case with optional message
  - `ErrorResponse`: with error code and message
  - `InspectResponse`: with font info, bounds, style properties
  - Verify that JSON keys use camelCase (the default Swift JSONEncoder behavior)

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentProtocolTests 2>&1 | tail -5`
  Expected: Compilation fails

- [ ] **Step 3:** Implement the models:
  - `ElementInfo`: struct with fields per the spec (role: UnifiedRole, label: String?, value: String?, description: String?, id: String?, enabled: Bool, focused: Bool, position: CGPoint?, size: CGSize?, childCount: Int, actions: [String], platformRole: String?, children: [ElementInfo]?). Conforms to Codable, Sendable, Equatable.
  - `WindowInfo`: struct with title: String?, windowType: String (window/dialog/menu/popover/tooltip/alert), size: CGSize, position: CGPoint, appName: String, focused: Bool, elements: [ElementInfo]? (populated in snapshots, nil in window listing)
  - `SnapshotResponse`: struct with windows: [WindowInfo]
  - `ActionResponse`: struct with success: Bool, message: String?
  - `ErrorResponse`: struct with error: String, details: String?
  - `InspectResponse`: struct with element: ElementInfo plus additional fields: fontFamily: String?, fontSize: Double?, fontWeight: String?, textColor: String?, bounds: CGRect?
  - Note: CGPoint, CGSize, CGRect need custom Codable conformance (they don't auto-conform on Linux, but we can handle that later — for macOS Phase 1 the default works)

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentProtocolTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Commit

  `git commit -m "feat: add shared agent protocol models (ElementInfo, WindowInfo, responses)"`

---

## Task 4: Accessibility Element Protocol & AXUIElement Wrapper

**Files:**
- Create: `Sources/guivision-agent/Accessibility/AccessibleElement.swift`
- Create: `Sources/guivision-agent/Accessibility/AXElementWrapper.swift`

- [ ] **Step 1:** Define the `AccessibleElement` protocol — the testable abstraction over AXUIElement. Methods:
  - `role() -> String?` — the platform role string (e.g., "AXButton")
  - `subrole() -> String?` — platform subrole if any
  - `label() -> String?` — AXTitle or AXDescription
  - `value() -> String?` — AXValue as string
  - `descriptionText() -> String?` — AXHelp or AXRoleDescription
  - `identifier() -> String?` — AXIdentifier (developer-assigned)
  - `isEnabled() -> Bool`
  - `isFocused() -> Bool`
  - `position() -> CGPoint?` — AXPosition
  - `size() -> CGSize?` — AXSize
  - `children() -> [any AccessibleElement]`
  - `actionNames() -> [String]` — AXActionNames
  - `performAction(_ name: String) throws` — AXPerformAction
  - `setAttribute(_ name: String, value: Any) throws` — AXSetAttributeValue
  - `fontInfo() -> (family: String?, size: Double?, weight: String?)?` — for text elements

- [ ] **Step 2:** Implement `AXElementWrapper` conforming to `AccessibleElement`, wrapping an `AXUIElement` reference. Each method calls the corresponding AX API function (`AXUIElementCopyAttributeValue`, etc.). Handle `AXError` results by returning nil for missing attributes rather than throwing.

- [ ] **Step 3:** Add a static method `AXElementWrapper.systemWide() -> AXElementWrapper` that wraps `AXUIElementCreateSystemWide()` — the entry point for tree walking.

- [ ] **Step 4:** Add a static method `AXElementWrapper.applicationElements() -> [AXElementWrapper]` that gets all running applications via the system-wide element.

- [ ] **Step 5:** Verify it builds (no unit tests for this file since it requires live AX access — tested via integration tests later)

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 6:** Commit

  `git commit -m "feat: add AccessibleElement protocol and AXUIElement wrapper"`

---

## Task 5: Role Mapper

**Files:**
- Create: `Sources/guivision-agent/Accessibility/RoleMapper.swift`
- Create: `Tests/GUIVisionAgentTests/RoleMapperTests.swift`
- Delete: `Tests/GUIVisionAgentTests/PlaceholderTest.swift`

Note: The `GUIVisionAgentTests` target needs to be configured to depend on the `guivision-agent` target's source files. Since Swift doesn't allow test targets to depend on executable targets directly, the accessibility layer should be structured as testable internal code. The test target should use `@testable import` or the agent's accessibility files should be accessible. One approach: make the `GUIVisionAgentTests` target's dependency point to the agent sources. Alternatively, move `RoleMapper` into `GUIVisionAgentProtocol` since it's pure mapping logic with no AX dependencies. **Recommended: put `RoleMapper` in `GUIVisionAgentProtocol`** since it maps String → UnifiedRole and has no platform API dependencies.

**Revised files:**
- Create: `Sources/GUIVisionAgentProtocol/RoleMapper.swift`
- Create: `Tests/GUIVisionAgentProtocolTests/RoleMapperTests.swift`

- [ ] **Step 1:** Write tests for role mapping:
  - Test basic widget mappings: "AXButton" → .button, "AXTextField" → .textfield, "AXCheckBox" → .checkbox, "AXRadioButton" → .radio, "AXSlider" → .slider, "AXPopUpButton" → .combobox
  - Test container mappings: "AXWindow" → .window, "AXGroup" → .group, "AXToolbar" → .toolbar, "AXScrollArea" → .scrollArea, "AXSplitGroup" → .splitter
  - Test menu mappings: "AXMenuBar" → .menuBar, "AXMenu" → .menu, "AXMenuItem" → .menuItem
  - Test content mappings: "AXStaticText" → .text, "AXImage" → .image, "AXHeading" → .heading
  - Test subrole disambiguation: ("AXGroup", subrole: "AXApplicationDialog") → .dialog, ("AXRadioButton", subrole: nil, in tab group context) → .tab
  - Test unknown role: "AXSomethingNew" → .unknown
  - Test case sensitivity: role strings should be matched exactly as macOS provides them

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentProtocolTests/RoleMapperTests 2>&1 | tail -5`
  Expected: Compilation fails

- [ ] **Step 3:** Implement `RoleMapper` as a struct with:
  - `static func map(role: String, subrole: String?) -> UnifiedRole` — the primary mapping function
  - An internal dictionary mapping AXRole strings to UnifiedRole values
  - Special-case logic for subrole disambiguation (AXGroup with dialog subroles, AXRadioButton in tab contexts)
  - Returns `.unknown` for any unmapped role

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentProtocolTests/RoleMapperTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Commit

  `git commit -m "feat: add RoleMapper for macOS AXRole to UnifiedRole mapping"`

---

## Task 6: Tree Walker

**Files:**
- Create: `Sources/guivision-agent/Accessibility/TreeWalker.swift`
- Create: `Tests/GUIVisionAgentTests/TreeWalkerTests.swift`

The TreeWalker depends on AccessibleElement protocol. Tests use a `MockAccessibleElement` struct conforming to the protocol to build fake UI trees.

Note: Update `GUIVisionAgentTests` target dependencies if needed — it needs access to the agent's `AccessibleElement` protocol and `TreeWalker`. Since executable targets can't be imported by test targets in SPM, consider creating a `GUIVisionAgentLib` internal library target that the executable and test target both depend on, OR put TreeWalker's logic into `GUIVisionAgentProtocol` with the AccessibleElement protocol. **Recommended: Create a `GUIVisionAgentLib` library target** for the agent's core logic (everything except AgentCLI.swift entry point), and have both `guivision-agent` executable and `GUIVisionAgentTests` depend on it.

**Additional file changes:**
- Modify: `Package.swift` — add `GUIVisionAgentLib` target

- [ ] **Step 1:** Add `GUIVisionAgentLib` library target to `Package.swift`:
  - Path: `Sources/GUIVisionAgentLib`
  - Dependencies: `GUIVisionAgentProtocol`, linker settings for `ApplicationServices` and `CoreGraphics`
  - Move `Accessibility/` and `Screenshot/` directories from `Sources/guivision-agent/` to `Sources/GUIVisionAgentLib/`
  - Update `guivision-agent` target to depend on `GUIVisionAgentLib`
  - Update `GUIVisionAgentTests` to depend on `GUIVisionAgentLib` and `GUIVisionAgentProtocol`

- [ ] **Step 2:** Verify the refactored structure builds

  Run: `swift build 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 3:** Create `MockAccessibleElement` in the test target — a struct conforming to `AccessibleElement` with configurable properties (role, label, children, etc.) for building fake trees in tests

- [ ] **Step 4:** Write TreeWalker tests:
  - Test walking a simple 3-level tree with depth=3 returns all elements
  - Test depth=1 returns only top-level children
  - Test filtering by role: only elements with matching role are included (but structure is preserved — filtered-out parents still appear if they have matching descendants)
  - Test filtering by label substring: case-insensitive match
  - Test that the walker converts AccessibleElement properties to ElementInfo correctly (role mapped via RoleMapper, label, value, etc.)
  - Test childCount is set correctly even when children are not expanded (depth limit reached)

- [ ] **Step 5:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentTests/TreeWalkerTests 2>&1 | tail -5`
  Expected: Compilation/test failures

- [ ] **Step 6:** Implement `TreeWalker`:
  - `static func walk(root: any AccessibleElement, depth: Int, roleFilter: UnifiedRole?, labelFilter: String?) -> [ElementInfo]`
  - Recursively walks children up to the specified depth
  - Applies role and label filters
  - Uses `RoleMapper.map()` for role conversion
  - Sets `childCount` from the actual number of children, regardless of depth expansion

- [ ] **Step 7:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentTests/TreeWalkerTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 8:** Commit

  `git commit -m "feat: add TreeWalker for recursive accessibility tree traversal"`

---

## Task 7: Query Resolver

**Files:**
- Create: `Sources/GUIVisionAgentLib/Accessibility/QueryResolver.swift`
- Create: `Tests/GUIVisionAgentTests/QueryResolverTests.swift`

- [ ] **Step 1:** Write tests for query resolution:
  - Test finding by role alone: given a tree with multiple element types, query for `button` returns only buttons
  - Test finding by label: query for label "Save" returns elements whose label contains "Save" (case-insensitive)
  - Test finding by role + label: `button` + "Save" returns only buttons labeled "Save"
  - Test finding by accessibility id: query for id "submitBtn" returns the element with that identifier
  - Test disambiguation with --index: when 3 buttons match, index=2 returns the second one (1-based)
  - Test no match: returns empty result (not an error)
  - Test multiple matches without index: returns all matches with enough context for the LLM to disambiguate
  - Test window scoping: query searches only within the specified window

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentTests/QueryResolverTests 2>&1 | tail -5`
  Expected: Compilation/test failures

- [ ] **Step 3:** Implement `QueryResolver`:
  - `static func resolve(in elements: [ElementInfo], role: UnifiedRole?, label: String?, id: String?, index: Int?) -> QueryResult`
  - `QueryResult` is an enum: `.found(ElementInfo)`, `.multiple([ElementInfo])`, `.notFound`
  - Walks the element tree recursively to find all matches
  - Applies filters: role exact match, label case-insensitive substring, id exact match
  - If index is provided and multiple match, returns the Nth match (1-based)
  - If multiple match without index, returns `.multiple` with all matches

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentTests/QueryResolverTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Commit

  `git commit -m "feat: add QueryResolver for element targeting by role/label/id"`

---

## Task 8: Agent CLI Skeleton, JSON Output, and Health Command

**Files:**
- Create: `Sources/guivision-agent/AgentCLI.swift` (replace placeholder)
- Create: `Sources/guivision-agent/JSONOutput.swift`
- Create: `Sources/guivision-agent/QueryOptions.swift`
- Create: `Sources/guivision-agent/WindowFilter.swift`
- Create: `Sources/guivision-agent/HealthCommand.swift`

- [ ] **Step 1:** Implement `JSONOutput` — a utility for writing JSON to stdout and errors to stderr:
  - `static func write<T: Encodable>(_ value: T)` — encodes to JSON and prints to stdout
  - `static func error(_ message: String, details: String?)` — writes ErrorResponse JSON to stderr and calls `Darwin.exit(1)`

- [ ] **Step 2:** Implement `QueryOptions` as a `ParsableArguments` struct with shared element targeting options used across action/inspect commands:
  - `--role` (String?), `--label` (String?), `--id` (String?), `--index` (Int?)
  - These are reused via `@OptionGroup` in action commands

- [ ] **Step 3:** Implement `WindowFilter` as a `ParsableArguments` struct:
  - `--window` (String?) — matches by title substring or app name

- [ ] **Step 4:** Implement `HealthCommand`:
  - Calls `AXIsProcessTrusted()` to check accessibility permissions
  - Outputs JSON: `{"accessible": true/false, "platform": "macos"}`
  - Exits with code 1 if not trusted

- [ ] **Step 5:** Implement `AgentCLI` as the `@main` entry point:
  - Register `HealthCommand` as a subcommand (other commands added in later tasks)
  - Command name: `guivision-agent`

- [ ] **Step 6:** Verify it builds and the health command runs locally

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

  Run: `.build/debug/guivision-agent health`
  Expected: JSON output with accessible: true (if permissions granted) or accessible: false

- [ ] **Step 7:** Commit

  `git commit -m "feat: add agent CLI skeleton with health command"`

---

## Task 9: Windows and Snapshot Commands

**Files:**
- Create: `Sources/guivision-agent/WindowsCommand.swift`
- Create: `Sources/guivision-agent/SnapshotCommand.swift`

- [ ] **Step 1:** Implement `WindowsCommand`:
  - Gets all running applications via `AXElementWrapper.applicationElements()`
  - For each application, gets its windows (AXWindows attribute)
  - Converts each window to a `WindowInfo` (title, type based on subrole, size, position, app name, focused state)
  - Includes transient surfaces (menus, dialogs, popovers) — identified by subrole
  - Outputs `WindowsResponse` JSON via `JSONOutput.write()`

- [ ] **Step 2:** Implement `SnapshotCommand`:
  - Options: `--mode` (interact/layout/full, default interact), `@OptionGroup WindowFilter`, `--role`, `--label`, `--depth` (default 3)
  - Gets windows (reuses WindowsCommand logic)
  - If `--window` provided, filters to matching windows
  - For each window, uses `TreeWalker.walk()` to get the element tree
  - Applies role and label filters
  - In `interact` mode: only include interactive elements (elements with actions or that are focusable) and structural context
  - In `layout` mode: include all elements with position and size
  - In `full` mode: include everything including font info
  - Outputs `SnapshotResponse` JSON

- [ ] **Step 3:** Register both commands in `AgentCLI`

- [ ] **Step 4:** Verify they build and run

  Run: `swift build --target guivision-agent && .build/debug/guivision-agent windows`
  Expected: JSON listing of current windows

  Run: `.build/debug/guivision-agent snapshot --depth 2`
  Expected: JSON snapshot of the accessibility tree (requires accessibility permissions)

- [ ] **Step 5:** Commit

  `git commit -m "feat: add windows and snapshot commands to agent"`

---

## Task 10: Action Commands

**Files:**
- Create: `Sources/guivision-agent/ActionCommands.swift`
- Create: `Sources/GUIVisionAgentLib/Accessibility/ActionPerformer.swift`

- [ ] **Step 1:** Implement `ActionPerformer`:
  - `static func press(element: any AccessibleElement) throws` — performs AXPress action
  - `static func setValue(element: any AccessibleElement, value: String) throws` — sets AXValue attribute
  - `static func focus(element: any AccessibleElement) throws` — sets AXFocused to true
  - `static func showMenu(element: any AccessibleElement) throws` — performs AXShowMenu action
  - Each method verifies the action is available before attempting it, throws a descriptive error if not

- [ ] **Step 2:** Implement action subcommands as an `ActionCommand` group containing `PressCommand`, `SetValueCommand`, `FocusElementCommand`, `ShowMenuCommand`:
  - Each uses `@OptionGroup QueryOptions` and `@OptionGroup WindowFilter`
  - Flow: get windows → filter by window → walk tree → resolve query → perform action → output ActionResponse
  - On disambiguation (multiple matches): output ErrorResponse listing the matches so the LLM can refine
  - On no match: output ErrorResponse with descriptive message

- [ ] **Step 3:** Register in `AgentCLI`

- [ ] **Step 4:** Verify build succeeds

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 5:** Commit

  `git commit -m "feat: add press, set-value, focus, show-menu action commands"`

---

## Task 11: Window Management Commands

**Files:**
- Create: `Sources/guivision-agent/WindowManageCommands.swift`

- [ ] **Step 1:** Implement window management subcommands as a `WindowManageCommand` group: `WindowFocusCmd`, `WindowResizeCmd`, `WindowMoveCmd`, `WindowCloseCmd`, `WindowMinimizeCmd`:
  - Each uses `@OptionGroup WindowFilter` to find the target window
  - `window-focus`: set AXMain and AXFocused attributes, bring app to front via NSRunningApplication or AX API
  - `window-resize`: set AXSize attribute to the specified width/height
  - `window-move`: set AXPosition attribute to the specified x/y
  - `window-close`: perform AXPress on the window's close button (AXCloseButton attribute)
  - `window-minimize`: toggle AXMinimized attribute
  - Each outputs ActionResponse JSON

- [ ] **Step 2:** Register in `AgentCLI`

- [ ] **Step 3:** Verify build succeeds

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 4:** Commit

  `git commit -m "feat: add window management commands (focus, resize, move, close, minimize)"`

---

## Task 12: Screenshot Commands

**Files:**
- Create: `Sources/GUIVisionAgentLib/Screenshot/WindowCapture.swift`
- Create: `Sources/guivision-agent/ScreenshotCommands.swift`

- [ ] **Step 1:** Implement `WindowCapture`:
  - `static func captureWindow(windowID: CGWindowID) -> CGImage?` — uses `CGWindowListCreateImage` with `.optionIncludingWindow` for a specific window
  - `static func captureRegion(windowID: CGWindowID, region: CGRect) -> CGImage?` — captures a window and crops to the specified region (relative to window top-left)
  - `static func captureElement(windowID: CGWindowID, elementBounds: CGRect, padding: Int) -> CGImage?` — captures the region around an element with optional padding
  - Convert CGImage to PNG Data

- [ ] **Step 2:** Implement screenshot subcommands as a `ScreenshotCommand` group: `ScreenshotElementCmd`, `ScreenshotWindowCmd`, `ScreenshotRegionCmd`:
  - `screenshot-element`: uses `@OptionGroup QueryOptions` and `@OptionGroup WindowFilter` to find the element, gets its bounds, captures with padding. Option: `--padding` (Int, default 0), `--output` (String, file path)
  - `screenshot-window`: uses `@OptionGroup WindowFilter` to find the window, captures it. Option: `--output`
  - `screenshot-region`: uses `@OptionGroup WindowFilter`, `--x`, `--y`, `--width`, `--height` for the region. Option: `--output`
  - All output PNG data to the specified file path, and output JSON with the file path and image dimensions

- [ ] **Step 3:** Register in `AgentCLI`

- [ ] **Step 4:** Verify build succeeds

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 5:** Commit

  `git commit -m "feat: add screenshot-element, screenshot-window, screenshot-region commands"`

---

## Task 13: Inspect and Wait Commands

**Files:**
- Create: `Sources/guivision-agent/InspectCommand.swift`
- Create: `Sources/guivision-agent/WaitCommand.swift`

- [ ] **Step 1:** Implement `InspectCommand`:
  - Uses `@OptionGroup QueryOptions` and `@OptionGroup WindowFilter`
  - Finds the target element via query resolution
  - Extracts detailed properties: all ElementInfo fields plus font info (family, size, weight) from AXFont attribute, text color if available, full bounds (position + size)
  - Outputs `InspectResponse` JSON

- [ ] **Step 2:** Implement `WaitCommand`:
  - Options: `@OptionGroup WindowFilter`, `--timeout` (Int, default 5 seconds)
  - Takes an initial snapshot hash (computed from the serialized tree structure)
  - Polls every 100ms, taking new snapshots and comparing hashes
  - Returns success JSON `{"changed": true}` when the tree changes
  - Returns `{"changed": false}` on timeout
  - If `--window` is provided, only monitors that window's subtree

- [ ] **Step 3:** Register both in `AgentCLI`

- [ ] **Step 4:** Verify build succeeds

  Run: `swift build --target guivision-agent 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 5:** Commit

  `git commit -m "feat: add inspect and wait commands to agent"`

---

## Task 14: Host CLI — AgentClient

**Files:**
- Create: `Sources/GUIVisionVMDriver/Agent/AgentClient.swift`
- Create: `Tests/GUIVisionVMDriverTests/Agent/AgentClientTests.swift`

- [ ] **Step 1:** Write tests for AgentClient:
  - Test command construction: given subcommand "snapshot" with args ["--mode", "interact", "--window", "Settings"], verify the full SSH command string is `/usr/local/bin/guivision-agent snapshot --mode interact --window Settings`
  - Test JSON response parsing: given a valid JSON string representing a SnapshotResponse, verify it deserializes correctly
  - Test error response parsing: given an ErrorResponse JSON on stderr with non-zero exit code, verify it produces a descriptive Swift error
  - Test that the agent binary path is configurable (default `/usr/local/bin/guivision-agent`)

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionVMDriverTests/AgentClientTests 2>&1 | tail -5`
  Expected: Compilation fails

- [ ] **Step 3:** Implement `AgentClient`:
  - Initialized with an `SSHClient` instance
  - `func exec(subcommand: String, args: [String]) async throws -> Data` — constructs the full command, calls `sshClient.exec()`, returns stdout data. If exit code is non-zero, parses stderr as ErrorResponse and throws.
  - Convenience methods: `snapshot(mode:window:role:label:depth:)`, `windows()`, `press(role:label:window:id:index:)`, etc. — each constructs the args array and calls `exec()`
  - `static let defaultBinaryPath = "/usr/local/bin/guivision-agent"`

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionVMDriverTests/AgentClientTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Commit

  `git commit -m "feat: add AgentClient for invoking in-VM agent via SSH"`

---

## Task 15: Host CLI — Agent Command Group & Output Formatter

**Files:**
- Create: `Sources/guivision/AgentCommand.swift`
- Create: `Sources/guivision/AgentFormatter.swift`
- Modify: `Sources/guivision/GUIVisionCLI.swift` (add AgentCommand to subcommands)
- Create: `Tests/GUIVisionAgentTests/AgentFormatterTests.swift`

- [ ] **Step 1:** Write tests for AgentFormatter:
  - Test snapshot formatting: given a SnapshotResponse JSON with a window containing nested elements, verify the output matches the LLM-optimized indented text format from the spec:
    ```
    "My App" (window) 800x600
      toolbar
        button "New" [enabled]
        button "Save" [enabled]
    ```
  - Test windows formatting: given a WindowsResponse, verify output lists windows with type, size, and app annotations
  - Test action formatting: given an ActionResponse, verify concise success/failure message
  - Test error formatting: given an ErrorResponse, verify clear error output
  - Test disambiguation formatting: given multiple matches, verify they're listed with enough context
  - Test that disabled elements show `[disabled]`, focused show `[focused]`, selected show `[selected]`
  - Test that elements with values show `value="..."`

- [ ] **Step 2:** Run tests to verify they fail

  Run: `swift test --filter GUIVisionAgentTests/AgentFormatterTests 2>&1 | tail -5`
  Expected: Compilation fails

- [ ] **Step 3:** Implement `AgentFormatter`:
  - `static func formatSnapshot(_ response: SnapshotResponse) -> String`
  - `static func formatWindows(_ response: WindowsResponse) -> String`
  - `static func formatAction(_ response: ActionResponse) -> String`
  - `static func formatError(_ response: ErrorResponse) -> String`
  - `static func formatInspect(_ response: InspectResponse) -> String`
  - The snapshot formatter recursively indents the element tree, showing role, label, state flags, and value. Non-interactive structural elements are shown without brackets. The format matches the spec example.

- [ ] **Step 4:** Run tests to verify they pass

  Run: `swift test --filter GUIVisionAgentTests/AgentFormatterTests 2>&1 | tail -5`
  Expected: All pass

- [ ] **Step 5:** Implement `AgentCommand` as an AsyncParsableCommand group with subcommands matching the spec. Each subcommand:
  - Uses `@OptionGroup ConnectionOptions` (needs SSH to be configured)
  - Creates an `AgentClient` from the resolved connection spec's SSH config
  - Calls the appropriate AgentClient method
  - Formats the response via AgentFormatter
  - Prints to stdout
  - Subcommands: SnapshotCmd, InspectCmd, PressCmd, SetValueCmd, FocusCmd, ShowMenuCmd, WindowsCmd, WindowFocusCmd, WindowResizeCmd, WindowMoveCmd, WindowCloseCmd, WindowMinimizeCmd, ScreenshotElementCmd, ScreenshotWindowCmd, WaitCmd

- [ ] **Step 6:** Add `AgentCommand.self` to the subcommands list in `GUIVisionCLI.swift`

- [ ] **Step 7:** Verify build succeeds

  Run: `swift build 2>&1 | tail -5`
  Expected: Build succeeds for both guivision and guivision-agent

- [ ] **Step 8:** Commit

  `git commit -m "feat: add guivision agent command group with LLM-optimized output formatting"`

---

## Task 16: Window-Relative Coordinates on Existing Commands

**Files:**
- Modify: `Sources/guivision/InputCommand.swift`
- Modify: `Sources/guivision/ScreenshotCommand.swift`

- [ ] **Step 1:** Add `--window` option (String?) to `ClickCommand`, `MouseDownCommand`, `MouseUpCommand`, `MoveCommand`, `ScrollCommand`, `DragCommand`, and `ScreenshotCommand`

- [ ] **Step 2:** In each command's `run()` method, when `--window` is provided:
  - Resolve the connection spec to get SSH config
  - Create an `AgentClient`
  - Call `agentClient.windows()` to get window list
  - Find the window matching the `--window` filter (by title substring)
  - Get the window's position (x, y)
  - Add the window position offset to the command's coordinates before sending through VNC
  - For screenshots: pass the window bounds as a crop region

- [ ] **Step 3:** Verify build succeeds

  Run: `swift build 2>&1 | tail -5`
  Expected: Build succeeds

- [ ] **Step 4:** Commit

  `git commit -m "feat: add --window option for window-relative coordinates on input/screenshot commands"`

---

## Task 17: Golden Image Script — Agent Installation & TCC/SIP Cycle

**Files:**
- Modify: `scripts/vm-create-golden-macos.sh`

- [ ] **Step 1:** Add a function `recovery_boot_disable_sip` to the script:
  - Shut down the VM gracefully
  - Boot the VM into Recovery Mode using `tart run --recovery`
  - Wait for the recovery environment to be available (SSH won't work in recovery — this needs VNC or serial console interaction, or tart-specific recovery commands)
  - Execute `csrutil disable` in the recovery environment
  - Shut down and reboot normally
  - Wait for SSH to become available again

  Note: The exact mechanism for running commands in tart recovery mode needs to be researched during implementation. It may involve using `tart run --recovery` with `--no-graphics` and piping commands via serial, or using VNC automation with the existing guivision tool. This step may need adjustment based on what tart supports.

- [ ] **Step 2:** Add a function `recovery_boot_enable_sip` — same as above but runs `csrutil enable`

- [ ] **Step 3:** Add a function `grant_accessibility_permission`:
  - Modify the TCC database at `~/Library/Application Support/com.apple.TCC/TCC.db`
  - Insert a row granting kTCCServiceAccessibility to `com.linkuistics.guivision.agent`
  - The SQL insert uses the binary's full path (`/usr/local/bin/guivision-agent`) as the client identifier
  - Verify the insert succeeded by querying the database

- [ ] **Step 4:** Add a function `install_agent`:
  - Build `guivision-agent` for release on the host: `swift build -c release --product guivision-agent`
  - SCP the binary from `.build/release/guivision-agent` to `/usr/local/bin/guivision-agent` in the VM
  - Set executable permissions: `chmod +x /usr/local/bin/guivision-agent`
  - Verify: `ssh vm guivision-agent health` returns `{"accessible": true, ...}`

- [ ] **Step 5:** Integrate these functions into the golden image creation flow, after the existing setup steps:
  1. (existing steps: SSH keys, Homebrew, Xcode CLI tools, wallpaper, etc.)
  2. Call `install_agent` — copy the binary first
  3. Call `recovery_boot_disable_sip`
  4. Call `grant_accessibility_permission`
  5. Call `recovery_boot_enable_sip`
  6. Verify agent health: `ssh vm guivision-agent health`
  7. (existing steps: shutdown, clone to golden)

- [ ] **Step 6:** Test the updated script manually:

  Run: `scripts/vm-create-golden-macos.sh --name guivision-golden-macos-test`
  Expected: Golden image created with agent installed, accessible, and SIP re-enabled

  Verify: Clone and boot the golden image, SSH in, run `guivision-agent health`, confirm `{"accessible": true}`

- [ ] **Step 7:** Commit

  `git commit -m "feat: add agent installation with SIP/TCC cycle to macOS golden image script"`

---

## Self-Review Checklist

**Spec coverage:**
- Unified element model with all fields → Task 3
- Query-based targeting (role, label, id, window, index) → Task 7
- Role vocabulary (AccessKit-based) → Task 2
- Role mapping (macOS AXRole → UnifiedRole) → Task 5
- Snapshot modes (interact, layout, full) → Task 9
- Window/surface listing → Task 9
- Action commands (press, set-value, focus, show-menu) → Task 10
- Window management → Task 11
- Screenshot commands (element, window, region) → Task 12
- Inspect command → Task 13
- Wait command → Task 13
- Health command → Task 8
- Host CLI agent subcommands → Task 15
- LLM-optimized output formatting → Task 15
- Window-relative coordinates on existing commands → Task 16
- SSH tunnel / connectivity → Task 14 (AgentClient uses SSHClient.exec)
- Golden image installation with SIP/TCC → Task 17
- Error handling (no graceful degradation) → Task 14 (AgentClient throws on failure)
- Transient notification buffer → Not explicitly covered. This is noted as a future enhancement since it requires a persistent process or filesystem-based notification watcher. The one-shot model captures notifications visible at snapshot time but cannot buffer dismissed ones. Acceptable for Phase 1.

**Placeholder scan:** No TBDs, TODOs, or "fill in later" in any task. Task 17 Step 1 notes a research need for tart recovery mode — this is flagged explicitly rather than papered over.

**Type consistency:** ElementInfo, WindowInfo, SnapshotResponse, ActionResponse, ErrorResponse, InspectResponse, UnifiedRole, RoleMapper, TreeWalker, QueryResolver, QueryResult, AccessibleElement, AXElementWrapper, AgentClient, AgentFormatter — all used consistently across tasks.
