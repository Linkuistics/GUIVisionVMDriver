# Session Log

### Session 22 (2026-04-11) — H11+H12: Linux deep tree walk + hidden element filtering
- **H11 investigation**: Dumped full AT-SPI tree for Nautilus, Text Editor, and Terminal via pyatspi in-VM
  - Nautilus: content (file names as `table cell`) at depth ~23, sidebar `list item` at depth ~17-22, toolbar `push button` at depth ~19-22
  - Text Editor: `text` content at depth 15, buttons at depth 14-17
  - Terminal: visible elements at depth 3-7 (GTK3, not GTK4 — shallower)
  - Root cause: generator used `depth=10`, GTK4/libadwaita apps wrap every widget in multiple `panel` (GtkBox/GtkStack) containers
- **H11 fix**: Increased `snapshot_kwargs` depth from 10 to 30 in `vm_generator.py`. Safe for macOS/Windows (trees naturally terminate at 3-10).
- **H12 investigation**: All 33 hidden hamburger menu items in GNOME Terminal have `STATE_SHOWING=False` in AT-SPI2
- **H12 pipeline**: Added `showing` field filtering at two levels:
  - `_collect_elements()` skips non-showing elements and all descendants (tree-level)
  - `element_to_detection()` skips non-showing elements (safety net)
  - Backward compat: `element.get("showing", True)` — old agents without the field are unaffected
- **H12 agent changes**:
  - Linux: `showing` field on `ElementInfo`, set from `STATE_SHOWING` via Atspi GI bindings
  - Swift CLI + macOS agent: `showing: Bool?` on `ElementInfo` (decode/encode/equality)
  - Windows agent: `Showing = !IsOffscreen` on `ElementInfo`
- **Bug fixes discovered during H12**:
  1. **pyatspi cache staleness**: Long-running agent process cached AT-SPI state from startup. `pyatspi.clearCache()` is a no-op (`pass`). Fix: use `gi.repository.Atspi` with `accessible.clear_cache()` + `get_state_set()` instead of `pyatspi.getState()`
  2. **Filter functions dropped showing**: `_filter_interactive_element()` and `_filter_layout_element()` reconstructed `ElementInfo` without copying `showing`, defaulting it to `True`. Added `showing=element.showing` to both.
- **Results** (8 Linux samples: Text Editor x3, Terminal x3, Nautilus x2; Firefox skipped):
  - **Text F1: 0.0%→51.7%** — Linux evaluation now works
  - **Precision: 0.0%→55.3%**
  - **Recall: 0.0%→48.5%**
  - **Char accuracy: 62.5%→28.9%** — decreased because we now have real GT to compare against (was inflated by 0-GT samples)
  - IoU F1: 2.4%→1.6% — slight decrease, expected (GTK4 content is deeply nested, bounding boxes less reliable)
  - GT counts: Nautilus 62-124 (was 0), Text Editor 9-12 (was 0), Terminal 6 (was 42)
- macOS/Windows not re-evaluated this session (changes are backward-compatible)
- TDD: 10 new pipeline tests, 554 total (up from 544)

### Session 21 (2026-04-11) — H4: Menu bar as ground truth source
- **Root cause**: macOS `enumerateWindows()` only walks `AXWindow` children. The system menu bar (`AXMenuBar`) is a sibling — invisible to snapshots.
- **Agent change**: Added `focusedAppMenuBar()` to `AgentServer.swift`: finds focused app's AXMenuBar, walks with depth=1 (top-level items only), returns as pseudo-window (`windowType: "menuBar"`)
- Modified `handleSnapshot()` to append menu bar (respects window filter and mode)
- AXMenuBarItem → `.menuItem` → "menu-item" (already in TEXT_CONTENT_ROLES) — no pipeline changes needed
- **Golden image rebuilt** with updated agent — TCC csreq baked in during SIP/TCC cycle
- **Results** (10 macOS samples):
  - **Text F1: 24.5%→45.2% (+20.7pp)** — nearly doubled, single most impactful hypothesis
  - **Precision: 18.0%→38.9% (+20.9pp)** — menu bar false positives → true positives
  - **Recall: 38.3%→53.9% (+15.6pp)** — new matchable GT targets
  - **Char accuracy: 45.1%→60.6% (+15.5pp)**
  - IoU F1: 6.7%→5.6% (-1.1pp) — OCR merges menu items into wide spans, poor spatial overlap
- Per-app menu bar items: Finder 8, TextEdit 8, Terminal 7, Safari 9 (1 sample missed — timing)
- GT per sample: Finder 39/70, TextEdit 12-14, Terminal 10, Safari 15/25 (menu items add 7-9 each)
- **Key insight**: OCR merges adjacent menu items ("File Edit View" as one span). Text-content matching handles this via word containment — this is why text metrics improved dramatically while IoU didn't.
- Windows: menu-item elements already in window AX tree, no change needed
- TDD: 4 new pipeline tests, 2 new agent tests
- 544 pipeline tests pass (up from 540), 20 agent tests pass (up from 18)

### Session 21b (2026-04-11) — Linux baseline + menu bar fix
- Ported menu bar fix to Linux agent (`_focused_app_menu_bar()` in accessibility.py) — same pattern as macOS but using AT-SPI2's `"menu bar"` role
- Rebuilt Linux golden image with updated agent
- Generated 8 samples: Text Editor x3, Terminal x3, Nautilus x2 (Firefox skipped — startup timeout)
- **Linux text F1: 0.0%** — fundamentally different GT issues:
  - Text Editor and Nautilus: AT-SPI tree returns only 1 `group` element per window (0 GT). GTK4/libadwaita apps may need deeper walks or different AT-SPI traversal.
  - Terminal: 42 GT elements — but 27 are hamburger menu items (hidden, not on screen) + 14 buttons ("Minimize", "Maximize", "Close") that are icon-only. Only 1 actual visible text element: the tab title.
  - No traditional menu bars: GNOME 42+ apps use header bars. Menu bar fix correctly finds nothing.
- **Key finding**: Linux GT problems are architectural — not just filtering issues. The AT-SPI tree for modern GTK4 apps is structurally different from macOS AX trees. Fixing this likely requires:
  1. Deeper tree walk (depth>3) or recursive traversal until text-content roles are found
  2. Filtering hamburger menu items (hidden menus generate GT for invisible content)
  3. Investigating why Nautilus/Text Editor expose so little of their tree

### Session 20 (2026-04-10) — H5+H6: Case-insensitive matching + Unicode normalization
- Added `normalize_text_for_matching()` function to evaluator: lowercase, Unicode whitespace→space, em/en-dash→hyphen, ×→x, smart quotes→straight, collapse whitespace
- Applied normalization to both GT and prediction labels in `match_by_text_content()` before word splitting and comparison
- Updated docstring to reflect case-insensitive behavior
- Translation table approach (`str.maketrans`) for O(n) normalization performance
- TDD: 20 new tests (8 for normalization function, 12 for matching behavior including case, NBSP, dashes, multiplication sign, smart quotes, combined scenarios)
- Updated existing `test_case_sensitive` → `test_case_insensitive_matching` (reversed assertion)
- **macOS results** (10 samples): text F1 21.2%→24.5%, char accuracy 21.1%→45.1%, recall 32.2%→38.3%
- **Windows results** (8 samples, Edge skipped): text F1 21.4%→24.6%, char accuracy 12.3%→20.6%, IoU F1 3.8%→8.3%
- **Terminal deep-dive**: "shell"↔"Shell" matched (H5), "admin — -zsh — 118×30"↔"• admin - -zsh - 118×30" matched (H6). Only "Split pane" unmatched (button description → H3b territory)
- Key insight: char/word accuracy jumped disproportionately because text-content matches score 1.0 each — more matches = more 1.0s in the average
- IoU improvements on Windows surprisingly large — case normalization found matches that also happened to have decent spatial overlap (compounding effect)
- Edge skipped on Windows (app not ready after 30s timeout) — 8 samples instead of 10
- 540 tests pass (up from 520)

### Session 19 (2026-04-10) — H10: Web content filtering + multi-platform scenarios
- Added `web-area` to UnifiedRole across macOS (Swift), Windows (C#), Linux (Python)
- macOS: AXWebArea→.webArea in RoleMapper.swift
- Linux: "document web"→"web-area" in role_mapper.py
- Windows: dual detection — `AutomationId == "RootWebArea"` (catches all Chromium-based: Edge, Chrome, Electron, CEF, ElectroBun, Tauri/WebView2) + FrameworkId fallback for non-Chromium web engines (Firefox)
- Pipeline: `_collect_elements()` skips descendants of `role == "web-area"` elements (+ backward compat `platformRole == "AXWebArea"`)
- Added `web-area` to ROLE_TO_REGION_LABEL as "content_area"
- Results: Safari GT 130→16, aggregate text F1 21.2% (above original 20.9%), IoU F1 6.3%, recall doubled to 32.2%
- Architectural decision: web content → a11y (not OCR); canvas/WebGL → OCR (a11y is empty)
- Added platform-specific scenarios to OCR generator: `default_scenarios(platform)` with macOS/Windows/Linux
  - Windows: Notepad, Windows Terminal, Edge, Explorer
  - Linux: gedit, GNOME Terminal, Firefox, Nautilus
  - Auto-detects platform from connect.json
- **Windows VM verified** (2026-04-10): Edge document has `id="RootWebArea"` (confirmed), Notepad document has `id=""` (correctly excluded). Detection is sound for Electron/ElectroBun/Tauri.
- Fixed vm-start.sh: Windows QEMU display device ramfb (was virtio-gpu-pci which doesn't work with golden image's drivers)
- 518 tests pass

### Session 18 (2026-04-10) — H3: Filter non-visual AX labels
- Added `is_text_content_role()` filter to `element_to_detection()` for OCR stage
- Added "static-text" to `TEXT_CONTENT_ROLES` (macOS AXStaticText maps to this in tests)
- IoU metrics improved significantly (F1 3.7%→5.0%, char 7.4%→15.6%)
- Per-app: Finder and TextEdit recall improved; Terminal still 0% (case/special char issues); Safari dominated by web content explosion (130 GT elements)
- Aggregate text-content F1 dropped 20.9%→16.9% — misleading, driven by Safari web content
- Key finding: web DOM content generates massive GT that overwhelms the evaluation. Safari on apple.com is not a fair test of OCR accuracy.
- Discovered two new hypotheses: H10 (web content depth limit) and H3b (button description filtering)
- Confirmed H5 (case-insensitive matching) would help Terminal: "shell"→"Shell" is an easy win
- 506 tests pass (18 new tests added, up from 488 baseline)

### Session 17 (2026-04-10) — Baseline established
- Implemented text-content matching: whole-word containment, one-to-many, IoU tiebreaker
- Fixed subprocess pipe inheritance bug in VMConnection._run (temp files instead of pipes)
- Generated 10 samples across 4 apps (TextEdit 3, Terminal 3, Safari 2, Finder 2)
- Baseline: 20.9% F1 text-content, 3.7% F1 IoU
- Key finding: the low accuracy is primarily a ground truth problem, not an OCR problem. OCR correctly reads visible text; the AX-derived ground truth includes non-visual descriptions and misses actual content text
- Detailed analysis of unmatched patterns documented in baseline section above
