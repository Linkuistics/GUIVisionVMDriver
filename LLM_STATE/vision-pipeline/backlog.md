# Vision Pipeline

Build a composable vision pipeline in `pipeline/` within GUIVisionVMDriver. The pipeline
extracts structured, machine-precise visual data from GUI screenshots — serving as an
evaluation function for LLM-driven GUI development. Each pipeline step is an independent
sub-project with generator/trainer/analyzer CLIs communicating via JSON. Python primary,
Swift only for Apple Vision OCR.

## Task Backlog

### Code review of VM-based OCR generation `[ocr]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Review Session 17's VM-generated OCR data quality. Compare synthetic
  vs VM accuracy results. Assess whether the text-content matching strategy is sound.
- **Results:** _pending_

### VM-based region generator + YOLO semantic classifier `[region-decomposition]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Extend region generator with VM support: launch multi-panel apps
  (Xcode, VS Code, terminals with splits), capture screenshots, use accessibility
  layout snapshots for ground truth. Map accessibility roles to semantic labels
  (window→content_area, toolbar→toolbar, etc.). Train YOLO semantic classifier.
  Evaluate on real screenshots across all three platforms. Test recursive refinement
  (does re-running on sub-regions help?).
- **Results:** _pending_

### Code review of region generator + semantic classifier `[region-decomposition]`
- **Status:** not_started
- **Dependencies:** VM-based region generator
- **Description:** Review YOLO model accuracy. Compare per-layout performance: synthetic
  vs real. Cross-platform accuracy comparison.
- **Results:** _pending_

### VM-based widget generator + remaining widget types + YOLO classifier `[widget-detection]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Extend widget generator with VM support. Implement remaining 11
  widget types in heuristic analyzer (radio, dropdown, tab, list_item, tree_item,
  menu_item, toolbar, scroll_bar, link, image). Fix widget analyzer refinements
  (absolute pixel margins, narrow HSV green range). Train per-platform YOLO models.
  Research: single model vs per-platform models.
- **Results:** _pending_

### Code review of widget generator + end-to-end `[widget-detection]`
- **Status:** not_started
- **Dependencies:** VM-based widget generator
- **Description:** Cross-platform widget classification accuracy comparison. Heuristic
  vs YOLO accuracy comparison on real screenshots. State detection accuracy review.
- **Results:** _pending_

### Visual properties — port from Redraw `[visual-properties]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Create `pipeline/visual-properties/` sub-project. Port Redraw's
  Tier 3 code: color extraction (`extract_fill_color`, `detect_gradient`), border
  detection (`detect_border`, `detect_border_radius`), shadow detection
  (`detect_shadow`). Adapt from PIL Image + list bounds to pipeline's types. Benchmark
  accuracy on real UI element crops from VMs.
- **Results:** _pending_

### Font detection `[visual-properties]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Create `pipeline/font-detection/` sub-project. Port Redraw's
  `font_matcher.py` (SSIM-based font matching). Build font reference database for
  system fonts per platform (macOS: SF Pro/Mono, Menlo; Windows: Segoe UI, Consolas;
  Linux: Cantarell, Ubuntu, Noto Sans). Generator renders known text in known fonts
  using platform-native rendering in-VM. Analyzer outputs font family, weight, size,
  style. Use `guivision agent inspect` font metadata as ground truth.
- **Results:** _pending_

### Code review of visual properties + font detection `[visual-properties]`
- **Status:** not_started
- **Dependencies:** visual properties, font detection
- **Description:** Validate visual property extraction and font detection accuracy on
  real UI elements from VMs across platforms. Document minimum reliable font size for
  family identification.
- **Results:** _pending_

### Icon classification `[icon-classification]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Create `pipeline/icon-classification/` sub-project. Define icon
  taxonomy (close, minimize, maximize, add, remove, settings, search, menu, chevron,
  etc.). Generator: programmatic SVG rendering + VM-based real icon capture. Train CNN
  or YOLO-cls classifier. Add color-state detection (icon color → semantic state).
- **Results:** _pending_

### Layout analysis `[layout-analysis]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Create `pipeline/layout-analysis/` sub-project. Primarily
  algorithmic: spacing measurement, alignment detection, grid conformance testing,
  distribution analysis, element grouping by proximity. Generator: programmatic known
  layouts + VM-based web pages with known CSS. Test with synthetic element arrangements.
- **Results:** _pending_

### WebView connector `[integration]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Create `pipeline/webview-connector/` sub-project (does NOT follow
  generator/trainer/analyzer pattern — it's a discovery/connector tool). CDP discovery
  for Electron/CEF apps. Accessibility-based WebView detection (`AXWebArea` on macOS,
  UIA WebView pattern on Windows). App-profile-based WebView location.
- **Results:** _pending_

### Pipeline orchestrator `[integration]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Build orchestrator that composes steps: sequential composition,
  selective composition, recursive/iterative flows. CLI:
  `python -m pipeline_orchestrator image.png --steps ocr,regions,widgets,visual-props`.
  Full integration tests on screenshots from all three platforms. Benchmark suite:
  timing per step, end-to-end latency, accuracy per step.
- **Results:** _pending_
