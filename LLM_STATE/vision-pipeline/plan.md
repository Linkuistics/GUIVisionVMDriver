# Task: Vision Pipeline Implementation

Build a composable vision pipeline in `pipeline/` within GUIVisionVMDriver. The pipeline extracts structured, machine-precise visual data from GUI screenshots — serving as an evaluation function for LLM-driven GUI development. Each pipeline step is an independent sub-project with generator/trainer/analyzer CLIs communicating via JSON. Python primary, Swift only for Apple Vision OCR.

This replaces GUIVisionPipeline and subsumes relevant parts of Redraw's visual analysis.

## Progress

### Phase 1: Foundation + OCR (establishes patterns for all subsequent phases)

- [x] **Session 1: Project scaffold + common library** _(completed 2026-04-08)_
  - Create `pipeline/` directory structure with top-level `pyproject.toml` and README
  - Create `pipeline/common/` package (using hatchling) with types ported from GUIVisionPipeline's `common/`:
    - `BoundingBox`, `Detection`, `DetectionSet`, `GroundTruth`, `GroundTruthSource` (from `types.py`)
    - `compute_metrics`, `MetricsResult` (from `metrics.py`)
    - `non_maximum_suppression` (from `nms.py`)
    - `load_image`, `save_image`, `crop_image` (from `image_io.py`)
    - `ABTestRunner` (from `ab_test.py`)
  - Add pipeline-specific types not in the old common: `PipelineStepResult` envelope (step name, version, timing, input metadata, output payload), `StepConfig` base
  - Port and adapt all tests from GUIVisionPipeline's `common/tests/`
  - Verify all tests pass with `pytest`
  - Establish the `pyproject.toml` pattern: each sub-project is a self-contained package with hatchling, depending on `pipeline-common` via relative path

- [x] **Session 2: Code review of Session 1** _(completed 2026-04-08)_
  - Review the common library against GUIVisionPipeline's original for correctness and completeness
  - Verify the package structure is self-contained and installable
  - Check that the `PipelineStepResult` envelope is sufficient for step composition (does it carry enough metadata for downstream steps?)
  - Verify test coverage — every public function should have tests
  - Check naming conventions, docstrings, type annotations consistency
  - Update plan with any issues found

- [x] **Session 3: OCR analyzer — Swift CLI extraction** _(completed 2026-04-08)_
  - Create `pipeline/ocr/` sub-project structure: `analyzer/`, `generator/`, `trainer/`, `tests/`
  - Extract the OCR functionality from `cli/macos/Sources/guivision/FindTextCommand.swift` into a standalone Swift CLI (`pipeline/ocr/analyzer/swift/`)
    - The Swift CLI should: accept an image path as input, run `VNRecognizeTextRequest`, output JSON to stdout
    - Output format: array of `{text, bounds: {x, y, width, height}, confidence}` — matching the design doc schema
    - Accept options: `--recognition-level accurate|fast`, `--languages en`, `--min-confidence 0.5`
    - Build with Swift Package Manager (standalone `Package.swift`, no dependency on the main guivision package)
  - Create the Python wrapper in `pipeline/ocr/analyzer/` that:
    - Calls the Swift CLI as a subprocess
    - Parses JSON output into `Detection` objects (label = text content)
    - Wraps results in `PipelineStepResult`
    - Handles errors (Swift CLI not found, build failures, invalid images)
  - Write tests:
    - Unit tests for the Python wrapper (mock subprocess)
    - Integration test that runs the Swift CLI on a test image with known text
    - Test that output conforms to `PipelineStepResult` schema
  - Create a simple test image with known text for the integration test (render text programmatically via Pillow)

- [x] **Session 4: Code review of Session 3** _(completed 2026-04-09)_
  - Review Swift CLI: is it truly standalone? Does the Package.swift build cleanly in isolation?
  - Review Python wrapper: error handling, subprocess management, JSON parsing robustness
  - Verify the analyzer can be invoked as a CLI (`python -m ocr_analyzer image.png`)
  - Check that the output schema matches the design document's OCR output format
  - Run integration tests — do they pass on a real macOS machine?
  - Update plan with any issues found

- [x] **Session 5: OCR generator — training data creation** _(completed 2026-04-09)_
  - Create `pipeline/ocr/generator/` package
  - Build the generator that creates labeled OCR test data:
    - **VM-based generation**: Use `guivision` to launch apps in VMs, capture screenshots, and use accessibility tree text labels as ground truth for evaluating the OCR analyzer on real-world text
  - Generator CLI: `python -m ocr_generator --output-dir data/ocr/ --connect-json connect.json`
  - Output format: `data/ocr/samples/` with images + `data/ocr/ground_truth/` with JSON ground truth files using the `GroundTruth` type from common
  - Write tests:
    - Test that VM generation creates valid image + ground truth pairs
    - Test that ground truth files conform to the `GroundTruth` schema
    - Test app readiness polling, interactions, timeout behavior

- [x] **Session 6: OCR trainer/evaluator — accuracy benchmarking** _(completed 2026-04-09)_
  - Create `pipeline/ocr/trainer/` package
  - Since OCR uses Apple Vision (no custom model training), the "trainer" is really an evaluator/benchmarker:
    - Run the analyzer on generated test data
    - Compute metrics: character-level accuracy, word-level accuracy, bounding box IoU, confidence calibration
    - Report results per category: font size buckets, contrast levels, font families
    - Establish minimum accuracy thresholds (e.g., >95% word accuracy for ≥12px text, >90% for 8-11px)
  - Evaluator CLI: `python -m ocr_trainer evaluate --data-dir data/ocr/ --output results.json`
  - Write tests:
    - Test metric computation with known predictions vs ground truth
    - Test threshold gating logic (pass/fail based on configured minimums)
    - Test report output format

- [x] **Session 7: Code review of Sessions 5-6 + end-to-end OCR validation** _(completed 2026-04-09)_
  - Review generator: does it produce diverse, representative training data?
  - Review evaluator: are the metrics meaningful? Are thresholds reasonable?
  - Run the full OCR pipeline end-to-end: generate data → run analyzer → evaluate → check thresholds
  - Verify the generator/trainer/analyzer pattern is clean and replicable for future steps
  - Document any patterns or utilities that should be extracted to common
  - Retrospective: is the sub-project structure working? Any friction points?
  - Update plan with learnings

### Phase 2: Region Decomposition

- [x] **Session 8: Geometric region decomposition** _(completed 2026-04-09)_
  - Create `pipeline/region-decomposition/` sub-project structure
  - Implement the geometric layer (always-on base layer):
    - Edge detection (Canny), contour analysis, line/split detection
    - Containment hierarchy building (which regions contain which)
    - Output: tree of rectangular regions with bounds
  - Port relevant concepts from GUIVisionPipeline's window-detection heuristic (`detect_windows_heuristic`) — adapt from window-level to region-level
  - Analyzer CLI: `python -m region_analyzer image.png --output regions.json`
  - Write tests first:
    - Test with synthetic images (colored rectangles, nested panels)
    - Test containment hierarchy correctness
    - Test edge cases: overlapping regions, very thin separators, rounded corners

- [x] **Session 9: Code review of Session 8** _(completed 2026-04-09)_
  - Review geometric analysis accuracy on real screenshots (capture a few from VMs)
  - Evaluate containment hierarchy quality
  - Check performance on large screenshots (4K resolution)
  - Update plan

- [x] **Session 10: Region decomposition generator + semantic classifier training** _(completed 2026-04-09)_
  - Build generator: launch multi-panel apps (Xcode, VS Code, terminals with splits) in VMs
  - Use accessibility trees as ground truth for region boundaries and semantics
  - Define semantic labels: editor_pane, sidebar, tab_bar, status_bar, toolbar, gutter, content_area, dialog, popup
  - Train initial YOLO model for semantic region classification
  - Evaluator: measure IoU accuracy (geometric) and classification accuracy (semantic) independently
  - Write tests for generator output format and evaluator metrics

- [x] **Session 11: Code review of Session 10 + region decomposition end-to-end** _(completed 2026-04-09)_
  - Review training data diversity — are all semantic categories well-represented?
  - Evaluate model accuracy — does it meet minimum thresholds?
  - Test on screenshots from all three platforms
  - Research note: document findings on recursive refinement (does re-running on sub-regions help?)
  - Update plan

### Phase 3: Widget Detection + State

- [x] **Session 12: Widget detection baseline** _(completed 2026-04-09)_
  - Create `pipeline/widget-detection/` sub-project structure
  - Implement heuristic baseline widget detector (port concepts from Redraw's `tier1/detector.py` and `tier2/classifier.py`)
  - Define widget type taxonomy: button, text_field, checkbox, radio, toggle, slider, dropdown, tab, list_item, tree_item, menu_item, toolbar, scroll_bar, progress_bar, label, link, image, separator
  - Define state properties: enabled/disabled, focused/unfocused, checked/unchecked, selected/unselected, expanded/collapsed, pressed/normal
  - Analyzer CLI: accepts region crop + optional OCR data, outputs widget type + state
  - Write tests with synthetic widget images

- [x] **Session 13: Code review of Session 12** _(completed 2026-04-09)_

- [x] **Session 14: Widget detection generator + model training** _(completed 2026-04-09)_
  - Build cross-platform generator: open apps on macOS, Windows, Linux VMs
  - Use accessibility trees for ground truth (widget type from role, state from attributes)
  - Manipulate widget states programmatically (disable buttons, check checkboxes, focus fields)
  - Capture before/after pairs for state detection training
  - Train per-platform YOLO models
  - Evaluate type accuracy and state accuracy independently
  - Write tests for generator and evaluator

- [x] **Session 15: VM-based data generation harness** _(completed 2026-04-09)_
  - Build a reusable Python harness in `pipeline/common/` for VM-based data generation
  - The harness wraps `guivision` CLI commands (screenshot, agent snapshot/press/set-value/focus, exec, input) into a Python API
  - Key abstractions:
    - `VMConnection(connect_json)` — wraps ConnectionSpec, provides methods for screenshot capture, accessibility queries, input simulation
    - `VMCaptureSession(connection, output_dir)` — manages a data generation session: capture screenshot + accessibility snapshot pairs, write ground truth
    - `AccessibilityGroundTruth` — convert `guivision agent snapshot` output (ElementInfo trees with role, label, value, enabled, focused, position, size) into `GroundTruth` + `Detection` objects with appropriate labels and metadata
  - Handle the role mapping: map UnifiedRole enum values (button, checkbox, textfield, slider, etc.) to widget type labels and region semantic labels
  - Write tests:
    - Unit tests with mocked subprocess calls
    - Integration test scaffolding that can run against a real VM (marked `@pytest.mark.integration`)
  - This harness is consumed by all subsequent VM-based generator sessions

- [x] **Session 16: Code review of Session 15** _(completed 2026-04-09)_
  - Review harness API — is it sufficient for OCR, region, and widget generators?
  - Verify role mapping covers all 152 UnifiedRole values relevant to pipeline steps
  - Check error handling: VM not running, agent not responding, screenshot failures
  - Update plan

- [x] **Session 17: VM-based OCR generator + real screenshot evaluation** _(completed 2026-04-10)_
  - AX visibility blocker resolved — apps now appear in accessibility tree after research plan findings applied
  - Text-content matching implemented as hybrid evaluation strategy (approach C):
    - `match_by_text_content()`: whole-word containment matching (one-to-many), IoU tiebreaker for multiple candidates
    - `MatchingStrategy` enum: `IOU` (default, backward-compatible) and `TEXT_CONTENT`
    - Matched pairs get 1.0 char/word accuracy (containment verified), unmatched GT scores 0.0
    - Detection metrics: TP = text-matched pairs, FP = predictions matching no GT, FN = unmatched GT
    - CLI: `--matching-strategy text_content`
  - Fixed subprocess pipe inheritance bug in `VMConnection._run`:
    - `subprocess.run(capture_output=True)` hangs because guivision's `_server` daemon inherits pipe FDs and keeps them open (300s idle timeout)
    - Fix: use temp files + `Popen.wait()` instead of `communicate()` — `wait()` waits for process exit, not pipe EOF
  - End-to-end validated: generate (10 samples, 4 apps) → analyze (Python wrapper) → evaluate → report
  - **Real VM accuracy results**:
    - IoU matching (baseline): 7.4% char, 5.9% word, 3.7% F1
    - Text-content matching: 17.1% char, 17.1% word, 20.9% F1
    - Per-app: Finder best (41-49% F1), Terminal/Safari/TextEdit lower (2-12% F1)
  - 488 total tests, all passing
  - **OCR accuracy research** continues in `LLM_STATE/ocr-accuracy/` — iterative improvement cycle with its own three-phase runner

- [ ] **Session 18: Code review of Session 17**
  - Review VM-generated OCR data quality
  - Compare synthetic vs VM accuracy results
  - Update plan

- [ ] **Session 19: VM-based region generator + real screenshot evaluation + YOLO semantic classifier**
  - Extend region generator with `--mode vm` support:
    - Launch multi-panel apps (Xcode, VS Code, terminals with splits) via `guivision exec`
    - Capture screenshots via `guivision screenshot`
    - Use `guivision agent snapshot --mode layout` to get window/panel structure from accessibility tree
    - Map accessibility roles to semantic labels: window→content_area, toolbar→toolbar, group→panel, splitGroup→editor_pane, etc.
  - Evaluate region analyzer on real screenshots:
    - Accuracy on real app layouts vs synthetic
    - Performance on 4K resolution (deferred from Session 9)
    - Cross-platform screenshots from macOS, Windows, Linux VMs (deferred from Session 11)
  - Train YOLO semantic region classifier (deferred from Sessions 10-11):
    - Use VM-captured screenshots with accessibility-tree-derived labels as training data
    - Port YOLO training wrapper from GUIVisionPipeline's `stages/window-detection/training/`
    - Classify regions into: editor_pane, sidebar, tab_bar, status_bar, toolbar, content_area, dialog, popup
    - Evaluate: IoU accuracy (geometric) and classification accuracy (semantic) independently
    - Goal: improve precision from 0.86 (geometric only) by filtering non-meaningful regions
  - Write integration tests

- [ ] **Session 20: Code review of Session 19**
  - Review YOLO model accuracy — does semantic classification improve precision?
  - Compare per-layout performance: synthetic vs real
  - Cross-platform accuracy comparison
  - Research note: recursive refinement — does re-running on sub-regions help?
  - Update plan

- [ ] **Session 21: VM-based widget generator + remaining widget types + YOLO widget classifier**
  - Extend widget generator with `--mode vm` support:
    - Open apps on macOS, Windows, Linux VMs via `guivision exec`
    - Use `guivision agent snapshot` to enumerate widgets by role (button, checkbox, textfield, slider, etc.)
    - For each widget: crop region from screenshot using element bounds, use role as ground truth type, use attributes (enabled, focused, value) as ground truth state
    - Manipulate widget states via `guivision agent press`, `guivision agent set-value`, `guivision agent focus`
    - Capture before/after pairs for state detection training
  - Implement remaining 11 widget types in heuristic analyzer (deferred from Session 12):
    - radio, dropdown, tab, list_item, tree_item, menu_item, toolbar, scroll_bar, link, image
    - Add synthetic rendering functions to `synthetic_widgets.py` for each
    - Create corresponding heuristic scorer functions in `analyzer.py`
  - Fix widget analyzer refinements (deferred from Session 13):
    - Use absolute pixel margins (2-3px) instead of 20% for small widgets in border_strength computation
    - Narrow HSV green detection hue range to reduce teal/cyan false positives
  - Train per-platform YOLO models (deferred from Session 14):
    - Use VM-captured widget crops with accessibility labels
    - Evaluate type accuracy and state accuracy independently
    - Research: single model vs per-platform models — which performs better?
  - Write integration tests

- [ ] **Session 22: Code review of Session 21 + widget detection end-to-end**
  - Cross-platform widget classification accuracy comparison
  - Heuristic vs YOLO accuracy comparison on real screenshots
  - State detection accuracy across widget types
  - Update plan

### Phase 4: Visual Properties + Font Detection

- [ ] **Session 23: Visual properties — port from Redraw**
  - Create `pipeline/visual-properties/` sub-project structure
  - Port Redraw's Tier 3 code into the pipeline step structure:
    - `color.py`: `extract_fill_color`, `detect_gradient` — adapt from PIL Image + list bounds to pipeline's types
    - `border.py`: `detect_border`, `detect_border_radius` — same adaptation
    - `shadow.py`: `detect_shadow` — same adaptation
  - Analyzer CLI: accepts element crop image + element type, outputs visual properties JSON
  - Write tests:
    - Port and adapt Redraw's existing tests
    - Add tests for the interface adaptation (BoundingBox ↔ list bounds)
    - Test with synthetic images (known colors, known borders, known shadows)

- [ ] **Session 24: Code review of Session 23**
  - Verify ported code produces identical results to Redraw's originals on the same inputs
  - Benchmark accuracy on real UI element crops from VMs (use VM harness to capture element crops)
  - Update plan

- [ ] **Session 25: Font detection**
  - Create `pipeline/font-detection/` sub-project structure
  - Port Redraw's `font_matcher.py` (SSIM-based font matching)
  - Build font reference database for system fonts per platform:
    - macOS: SF Pro, SF Mono, Menlo, Helvetica Neue, New York
    - Windows: Segoe UI, Consolas, Cascadia Code, Arial
    - Linux: Cantarell, Ubuntu, Noto Sans, DejaVu Sans Mono
  - Generator: render known text in known fonts at known sizes using platform-native rendering (use `guivision exec` to render in-VM for platform-accurate glyph appearance)
  - Analyzer: accepts text region crop + OCR result, outputs font family, weight, size, style
  - Evaluator: measure per-property accuracy (family match rate, size error distribution, weight confusion matrix)
  - Use `guivision agent inspect` font metadata (fontFamily, fontSize, fontWeight) as ground truth for real-screenshot evaluation
  - Write tests for each property detection independently

- [ ] **Session 26: Code review of Sessions 24-25 + visual properties end-to-end**
  - Validate visual property extraction on real UI elements from VMs
  - Validate font detection accuracy across font families and sizes, per platform
  - Document minimum reliable font size for family identification
  - Update plan

### Phase 5: Icon Classification + Layout Analysis

- [ ] **Session 27: Icon classification**
  - Create `pipeline/icon-classification/` sub-project structure
  - Define icon taxonomy from design doc: close, minimize, maximize, add, remove, settings, search, menu, chevron, etc.
  - Generator:
    - Programmatic: render icons from SVG sources at various sizes and color schemes
    - VM-based: capture real icons from apps via `guivision screenshot` + region cropping, using `guivision agent snapshot` to identify icon elements by role (image, button with no text label)
  - Train CNN or YOLO-cls classifier
  - Add color-state detection (icon color → semantic state: active, inactive, error, warning)
  - Evaluator: per-icon-type precision/recall
  - Write tests

- [ ] **Session 28: Code review of Session 27**

- [ ] **Session 29: Layout analysis**
  - Create `pipeline/layout-analysis/` sub-project structure
  - Implement primarily algorithmic analysis (geometry, not ML):
    - Spacing measurement between adjacent elements
    - Alignment detection (shared edges, centers, baselines)
    - Grid conformance testing (8px grid, 4px grid, etc.)
    - Distribution analysis (even spacing, justify patterns)
    - Element grouping by proximity
  - Analyzer CLI: accepts list of detected elements with bounding boxes, outputs spatial relationships
  - Generator:
    - Programmatic: create layouts with known spacing/alignment
    - VM-based: use Playwright (installed in golden images, accessed via `guivision exec`) to create web pages with known CSS layouts; capture screenshots and compare detected layout against known CSS properties
  - Write tests with synthetic element arrangements where expected spacing/alignment is known

- [ ] **Session 30: Code review of Sessions 28-29 + Phase 5 end-to-end**
  - Icon classification accuracy review
  - Layout analysis accuracy on real app screenshots from VMs
  - Integration test: full pipeline so far (OCR → region → widget → visual props → layout) on real screenshots
  - Update plan

### Phase 6: WebView Connector + Integration

- [ ] **Session 31: WebView connector**
  - Create `pipeline/webview-connector/` sub-project (does NOT follow generator/trainer/analyzer pattern — it's a discovery/connector tool)
  - Implement CDP discovery for Electron, CEF apps
  - Implement accessibility-based WebView detection (`AXWebArea` on macOS, UIA WebView pattern on Windows) via `guivision agent snapshot`
  - Implement app-profile-based WebView location
  - Connector CLI: accepts window/process identifier, outputs WebView bounds + CDP endpoint if available
  - Write tests with mock CDP endpoints + integration tests against real Electron apps in VMs

- [ ] **Session 32: Code review of Session 31**

- [ ] **Session 33: Pipeline orchestrator + full integration**
  - Build a pipeline orchestrator that composes steps:
    - Sequential composition (OCR → font detection)
    - Selective composition (run only specified steps)
    - Handle recursive/iterative flows (widget detection triggering re-OCR on crops)
  - Orchestrator CLI: `python -m pipeline_orchestrator image.png --steps ocr,regions,widgets,visual-props --output result.json`
  - Full integration tests: run complete pipeline on screenshots from all three platforms via VM harness
  - Benchmark suite: timing per step, end-to-end latency, accuracy per step
  - Write tests for orchestrator logic (step ordering, dependency resolution, error propagation)

- [ ] **Session 34: Code review of Session 33 + final validation**
  - Review orchestrator design — is composition flexible enough?
  - Run full pipeline on diverse real-world screenshots from macOS, Windows, Linux VMs
  - Performance review: identify bottlenecks, benchmark on 4K screenshots
  - Final accuracy report across all steps and platforms
  - Retrospective: document what worked, what to improve for Phase 7 (research)

### Phase 7: Research + Refinement (future — not scheduled)

This phase covers research topics from the design document:
- VLM-based classification (Florence-2) for novel widget styles
- Multi-step pipeline composition (recursive OCR, iterative refinement)
- Cross-platform model generalisation studies
- Learned font embeddings (replacing SSIM baseline)
- Custom font support workflow
- Performance optimisation (batch processing, model quantisation, ONNX/CoreML export)
- Vision heuristic for WebView boundary detection from pixels alone

These will be planned in detail when Phases 1-6 are complete.

## Reusable Components Reference

| Source | What to port | Adaptation |
|--------|-------------|------------|
| `GUIVisionPipeline/common/` | BoundingBox, Detection, DetectionSet, GroundTruth, metrics, NMS, image_io, ABTest | Direct port — types are well-designed |
| `GUIVisionPipeline/stages/window-detection/generator/` | VMCaptureSession, WindowScenario pattern | Adapt into a reusable generator harness in common |
| `GUIVisionPipeline/stages/window-detection/training/` | TrainConfig, YOLO training wrapper | Port for steps that use YOLO |
| `Redraw/python/redraw/tier3/color.py` | extract_fill_color, detect_gradient | Adapt bounds format (list[float] → BoundingBox) |
| `Redraw/python/redraw/tier3/border.py` | detect_border, detect_border_radius | Same adaptation |
| `Redraw/python/redraw/tier3/shadow.py` | detect_shadow | Same adaptation |
| `Redraw/python/redraw/tier3/font_matcher.py` | FontMatcher, SSIM matching | Port with reference DB builder |
| `Redraw/python/redraw/schema.py` | DrawingPrimitive, UINode concepts | Inform output schema design |
| `cli/macos/.../FindTextCommand.swift` | VNRecognizeTextRequest wrapper | Extract into standalone Swift CLI |
