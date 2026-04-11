# OCR Accuracy Research

Iterative research to improve OCR evaluation accuracy. Each session picks a hypothesis, implements it, evaluates against the baseline, and updates this document with findings.

## Current Baseline

Established 2026-04-11 (Session 21, after H4). Multi-platform.

### macOS (10 samples: TextEdit, Terminal, Safari, Finder)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 6.7% | 60.6% |
| Word accuracy | 6.0% | 60.6% |
| Detection F1 | 5.6% | 45.2% |
| Precision | 5.0% | 38.9% |
| Recall | 6.4% | 53.9% |

H4 (menu bar GT) nearly doubled text F1: 24.5%→45.2% (+20.7pp). Precision more than doubled: 18.0%→38.9%. IoU decreased slightly (-1.1pp F1) because OCR merges menu items into wide spans that don't spatially match individual GT items.

### Windows (8 samples: Notepad, Windows Terminal, Explorer; Edge skipped)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 9.5% | 20.6% |
| Word accuracy | 9.2% | 20.6% |
| Detection F1 | 8.3% | 24.6% |
| Precision | 13.1% | 33.9% |
| Recall | 6.1% | 19.3% |

Windows unchanged from Session 20. Menu bar items were already in the AX tree on Windows.

### Linux (8 samples: GNOME Text Editor, GNOME Terminal, Nautilus; Firefox skipped)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 1.1% | 28.9% |
| Word accuracy | 0.0% | 28.9% |
| Detection F1 | 1.6% | 51.7% |
| Precision | 2.3% | 55.3% |
| Recall | 1.3% | 48.5% |

Session 22 (H11+H12): **Text F1 0.0%→51.7%** — Linux evaluation now works. Two root causes fixed:
- **H11: Deep tree walk** — GTK4/libadwaita apps nest content at depth 15-25. Generator depth increased from 10 to 30. Nautilus now has 62-124 GT detections (was 0).
- **H12: Hidden element filtering** — Added `showing` field (from AT-SPI2 `STATE_SHOWING`) to filter invisible hamburger menu items. Terminal GT dropped from 42 to 6.
- Also fixed: pyatspi cache staleness (Atspi GI bindings with `clear_cache()`), and `_filter_interactive`/`_filter_layout` dropping the `showing` field.
- Firefox still skipped due to startup timeout.

### Per-App Breakdown (text-content matching)

| App | Samples | GT Dets (menu+other) | OCR Preds | Key Issue |
|---|---|---|---|---|
| Finder | 2 | 39 (8+31), 70 (8+62) | 36, 49 | Button labels ("back", "forward", "Share") remain unmatched — OCR doesn't read toolbar icon text. Menu bar items now matched. |
| TextEdit | 3 | 12-14 (8+4-6) | 22-25 | Button descriptions ("font size", "list style") not visible text. Menu bar items now matched. |
| Terminal | 3 | 10 (7+3) | 30-31 | Menu bar items matched. "Split pane" (button description) still unmatched. Terminal content text is the main gap (H1). |
| Safari | 2 | 15, 25 (0+15, 9+16) | 17, 18 | Safari sample 6 missed menu bar (timing). App chrome GT only (web content filtered). |

### Unmatched Pattern Analysis

- **~~OCR finds but GT doesn't have~~**: Menu bar text now included in GT (H4 done)
- **GT has but OCR doesn't find**: Button descriptions ("back", "forward", "font size", "list style", "Split pane") — button role with description-style labels, not rendered text (H3b target)
- **~~GT has but matching fails~~**: Case and special char issues now fixed by H5+H6
- **OCR merges adjacent items**: "File Edit View" detected as one span — text-content matching handles this (word containment) but IoU can't match

## Hypotheses

Ordered by current priority. Updated after Session 22: H11+H12 done (Linux text F1 0.0%→51.7%).

Next priorities:
1. **H3b** (button description filtering) — cross-platform false negative reduction. Buttons like "Back", "Forward", "Minimize" are icon-only but have text labels in GT.
2. **H1/H2** (constructed GT for Terminal/TextEdit content) — terminal and editor body text is the main GT gap
3. **H7** (fuzzy matching) — OCR misreads might cause missed matches
4. **H8** (word-level OCR) to fix IoU matching
5. **H9** (confidence threshold tuning) — precision improvement

### H1: Constructed ground truth for Terminal
- **Status**: not_started
- **Tier**: 1 — Ground truth generation
- **Problem**: AX tree has only 5 structural elements (window chrome). OCR correctly finds 32 lines of terminal text (prompt, command output). The ground truth is measuring the wrong thing entirely.
- **Approach**: After typing commands (`ls -la /`, `cal`), construct GT from the known command + expected output patterns. Use the typed text and command output as GT labels, with bounding boxes estimated from character grid (Terminal uses fixed-width font, so row/col maps to pixels).
- **Success criteria**: Terminal text-content recall >60%
- **Results**: _pending_

### H2: Constructed ground truth for TextEdit
- **Status**: not_started
- **Tier**: 1 — Ground truth generation
- **Problem**: AX tree concatenates all typed text into one label without line breaks ("The quick brown fox...HEADING IN CAPS..."). Toolbar labels are descriptions ("bold", "italic", "underline") not visual text. OCR correctly reads individual lines.
- **Approach**: Use the text we type via interactions as GT, split into lines. Each line becomes a separate GT detection with bounds estimated from font size and line height.
- **Success criteria**: TextEdit text-content recall >50%
- **Results**: _pending_

### H3: Filter non-visual AX labels from ground truth
- **Status**: done
- **Tier**: 1 — Ground truth generation
- **Problem**: ~40% of unmatched GT labels are accessibility descriptions of icons/controls that have no visual text representation: "sidebar", "clock", "Arrow Down Circle", "show sidebar", "Go back", "bold", "italic". These inflate false negatives.
- **Approach**: Added `is_text_content_role()` check in `element_to_detection()` for the OCR stage. Only elements with roles in `TEXT_CONTENT_ROLES` (text, button, heading, link, tab, menu-item, etc.) generate OCR ground truth. Also added "static-text" to `TEXT_CONTENT_ROLES`.
- **Success criteria**: Aggregate false negatives reduced by >30%; no true text elements filtered
- **Results**:
  - IoU metrics improved: F1 3.7%→5.0%, char 7.4%→15.6%, word 5.9%→13.3%
  - Per-app: Finder GT 56-131→31-62 (image descriptions removed), TextEdit GT 21-23→4-6, Terminal GT 5→3, Safari GT 18-172→15-130
  - Finder and TextEdit recall improved significantly
  - **Unexpected finding**: Aggregate text-content F1 dropped 20.9%→16.9% because Safari web content (links, headings, text) are ALL text-content roles, generating 130 GT elements the filter can't remove. This exposed a new problem: web DOM content granularity mismatch.
  - **Remaining button description problem**: Button labels like "font size", "list style", "document actions", "back", "forward" survive the filter since button is a text-content role. These are descriptions, not rendered text. Need a separate heuristic (H3b).
  - 506 tests pass (18 new tests added for the filter)

### H4: Add menu bar as ground truth source
- **Status**: done
- **Tier**: 1 — Ground truth generation
- **Problem**: OCR consistently finds menu bar text ("TextEdit", "File", "Edit", "View", "Window", "Help") but these don't appear in the AX snapshot GT, creating false positives. Each app has 5-10 menu items that OCR correctly reads.
- **Approach**: Modified macOS agent's `handleSnapshot` to include the focused app's AXMenuBar as a pseudo-window (windowType="menuBar"). Added `focusedAppMenuBar()` function that walks AXMenuBar children with depth=1 (only top-level AXMenuBarItems, not dropdown contents). AXMenuBarItem maps to `.menuItem` → "menu-item" which is already in TEXT_CONTENT_ROLES, so no pipeline changes needed.
- **Success criteria**: Per-app false positives reduced by 5-10; menu text counted as true positives
- **Results**:
  - **Text F1: 24.5%→45.2% (+20.7pp)** — nearly doubled. Single most impactful hypothesis.
  - **Precision: 18.0%→38.9% (+20.9pp)** — menu bar items converted from false positives to true positives
  - **Recall: 38.3%→53.9% (+15.6pp)** — adding menu bar GT creates new matchable targets
  - **Char accuracy: 45.1%→60.6% (+15.5pp)**
  - IoU F1: 6.7%→5.6% (-1.1pp) — expected: OCR merges menu items into wide spans, poor spatial overlap with individual GT items
  - Per-app menu items: Finder 8, TextEdit 8, Terminal 7, Safari 9 (1 sample missed — timing)
  - Golden image rebuilt with updated agent (TCC csreq baked in)
  - 544 pipeline tests pass (4 new H4 tests), 20 agent tests pass (2 new)
  - Windows: menu-item elements already in window AX tree, no change needed

### H5: Case-insensitive text-content matching
- **Status**: done
- **Tier**: 2 — Matching improvement
- **Problem**: "shell" (GT) doesn't match "Shell" (OCR). Case differences between AX labels and OCR text cause missed matches.
- **Approach**: Added `normalize_text_for_matching()` function that lowercases text before word splitting. Applied to both GT and prediction labels in `match_by_text_content()`.
- **Success criteria**: Measurable recall improvement (even small)
- **Results**:
  - macOS text recall: 32.2%→38.3% (+6.1pp), char accuracy: 21.1%→45.1% (+24pp)
  - Terminal: "shell" now matches "Shell" — 2/3 GT elements matched (was 0/3)
  - Combined with H6 in same session

### H6: Normalize special characters in matching
- **Status**: done
- **Tier**: 2 — Matching improvement
- **Problem**: AX labels contain special characters and formatting ("admin — -zsh — 118×30", Unicode symbols in Safari) that prevent word matching against OCR text.
- **Approach**: Added `normalize_text_for_matching()` with translation table: NBSP→space, em/en-dash→hyphen, ×→x, smart quotes→straight quotes. Collapses whitespace and strips.
- **Success criteria**: Handles decorated labels that currently fail matching
- **Results**:
  - Terminal: "admin — -zsh — 118×30" now matches OCR "• admin - -zsh - 118×30"
  - Windows IoU F1: 3.8%→8.3% (+118%) — normalization helped find matches with good spatial overlap
  - Combined with H5 in same session, 20 new tests added (540 total)

### H7: Fuzzy word matching
- **Status**: not_started
- **Tier**: 2 — Matching improvement
- **Problem**: OCR may misread characters ("Helverica" for "Helvetica"). Current whole-word matching requires exact match.
- **Approach**: Allow near-matches using edit distance threshold (e.g., Levenshtein distance <= 1 for words >4 chars).
- **Success criteria**: Marginal recall improvement without introducing false positives
- **Results**: _pending_

### H8: Word-level OCR detection
- **Status**: not_started
- **Tier**: 3 — Analyzer improvement
- **Problem**: Apple Vision OCR groups nearby text into lines. A single detection "TextEdit File Edit View" spans the entire menu bar. This makes IoU matching useless and limits spatial precision.
- **Approach**: Investigate Apple Vision API for word-level bounding boxes (VNRecognizedText provides character-level bounds). Modify the Swift CLI to output per-word detections.
- **Success criteria**: IoU matching F1 improves significantly; predictions map 1:1 with GT elements
- **Results**: _pending_

### H9: Confidence threshold tuning
- **Status**: not_started
- **Tier**: 3 — Analyzer improvement
- **Problem**: Some low-confidence OCR detections may be noise (artifacts, partial text).
- **Approach**: Evaluate precision/recall trade-off at different confidence thresholds (0.3, 0.5, 0.7, 0.9).
- **Success criteria**: Find optimal threshold that improves precision without significant recall loss
- **Results**: _pending_

### H10: Filter web content from ground truth via web-area role
- **Status**: done
- **Tier**: 1 — Ground truth generation
- **Problem**: Safari loading apple.com generates 130 text-content GT elements from the web DOM (every link, heading, text paragraph). OCR reads the page as ~18 text lines. This granularity mismatch dominates the aggregate, making Safari recall ~2%.
- **Approach**: Added `web-area` to UnifiedRole across all 3 platforms. macOS maps AXWebArea→web-area, Linux maps "document web"→"web-area", Windows detects web Document via FrameworkId ("Chrome"/"Edge"). Pipeline skips descendants of web-area elements in `_collect_elements()`. Backward compat: also checks `platformRole == "AXWebArea"` for old agent binaries.
- **Architectural decision**: Web content should use a11y directly (structured, semantic), not OCR. Canvas/WebGL is the exception — those need OCR because a11y tree is empty. Ground truth for canvas test pages can be constructed programmatically.
- **Success criteria**: Safari GT count closer to OCR prediction count; aggregate F1 not dominated by one app
- **Results**:
  - Safari GT: 130→16 detections (web DOM filtered, only app chrome remains)
  - Aggregate text F1: 16.9%→21.2% (exceeds Session 17 baseline of 20.9%)
  - Aggregate IoU F1: 5.0%→6.3% (70% improvement from original 3.7%)
  - Text recall doubled: 18.3%→32.2%
  - All metrics improved across the board
- **Origin**: Discovered during H3

### H3b: Filter button description labels
- **Status**: not_started
- **Tier**: 2 — Ground truth generation
- **Problem**: Button labels like "font size", "list style", "document actions", "back", "forward", "Share", "Edit Tags" survive H3 filtering because button is a text-content role. But these are AX descriptions of toolbar icons, not rendered text. They inflate false negatives. Also affects Linux: Terminal exposes "Minimize", "Maximize", "Close", "Find" — all icon-only buttons.
- **Approach**: Heuristic filter for button/toggle elements: exclude if label matches description patterns (contains spaces + lowercase words, matches known toolbar patterns). Or: cross-reference with the visual content — if the button's bounding box contains no OCR text, it's likely icon-only.
- **Success criteria**: Reduce Finder/TextEdit/Terminal false negatives from button descriptions by >50%
- **Results**: _pending_
- **Origin**: Discovered during H3 — buttons with description-style labels remain in GT. Confirmed cross-platform during Session 21b (Linux Terminal has same issue).

### H11: Linux AT-SPI shallow tree for GTK4/libadwaita apps
- **Status**: done
- **Tier**: 1 — Ground truth generation (Linux-specific)
- **Problem**: Nautilus and GNOME Text Editor return only 1 `group` element per window at depth=3. The AT-SPI tree for GTK4/libadwaita apps has much more structural nesting than macOS AX trees (e.g., `frame → panel × 12 → ... → table cell`).
- **Approach**: Investigated AT-SPI tree depth by dumping full tree via pyatspi in-VM. Nautilus content elements (file names) are at depth ~23, Text Editor buttons at depth ~14-17. Fixed by increasing generator snapshot depth from 10 to 30.
- **Success criteria**: Nautilus and Text Editor GT >0 detections; labels match visible UI text
- **Results**:
  - Nautilus: 0→62-124 GT detections (file names, sidebar items, toolbar buttons)
  - Text Editor: 0→9-12 GT detections (buttons, labels, text content area)
  - Combined with H12: **Linux text F1: 0.0%→51.7%**
  - Also needed: Atspi GI bindings (`accessible.clear_cache()` + `get_state_set()`) to bypass pyatspi's stale cache in the long-running agent process
  - Also needed: fix `_filter_interactive_element()` and `_filter_layout_element()` which dropped the `showing` field when reconstructing ElementInfo
  - 554 pipeline tests pass (10 new for H12)
- **Origin**: Discovered during Session 21b — Linux baseline shows 0 GT for 2 of 3 tested apps

### H12: Filter hidden hamburger menu items from GT
- **Status**: done
- **Tier**: 1 — Ground truth generation (Linux-specific, partially cross-platform)
- **Problem**: GNOME Terminal exposes 27 menu items (New Tab, Copy, Paste, Preferences, etc.) from its hamburger menu even when the menu is closed. These items are not visible on screen, creating 27 unmatchable GT elements per sample.
- **Approach**: Added `showing` field to Linux agent's ElementInfo, set from AT-SPI2 `STATE_SHOWING` via Atspi GI bindings. Pipeline filters elements with `showing=False` in both `_collect_elements()` (tree-level, skips descendants) and `element_to_detection()` (safety net). Also added `showing: Bool?` to Swift CLI/agent ElementInfo for pass-through. Windows agent gets `Showing = !IsOffscreen`.
- **Success criteria**: Terminal GT drops from 42 to ~5-10 (only visible chrome elements); no visible text elements filtered
- **Results**:
  - Terminal GT: 42→6 per sample (only visible tab title, buttons remain)
  - Hidden elements: 57 of 72 total Terminal elements filtered (menu bar, hamburger popup, zoom controls)
  - Pipeline correctly skips non-showing elements AND their descendants
  - Backward compatible: agents that don't emit `showing` default to `True`
  - 10 new pipeline tests (5 in TestElementToDetection, 4 in TestFlattenElements, 1 in TestSnapshotToGroundTruth)
- **Origin**: Discovered during Session 21b — Terminal GT dominated by invisible hamburger menu items
