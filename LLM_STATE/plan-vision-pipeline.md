# Task: Vision Pipeline Implementation

Build a composable vision pipeline in `pipeline/` within GUIVisionVMDriver. The pipeline extracts structured, machine-precise visual data from GUI screenshots — serving as an evaluation function for LLM-driven GUI development. Each pipeline step is an independent sub-project with generator/trainer/analyzer CLIs communicating via JSON. Python primary, Swift only for Apple Vision OCR.

This replaces GUIVisionPipeline and subsumes relevant parts of Redraw's visual analysis.

## Session Continuation Prompt

```
You MUST first read `../LLM_CONTEXT/index.md`.

# Continue: Vision Pipeline

Read `LLM_STATE/plan-vision-pipeline.md` and review current progress. Continue from the next
incomplete step. After completing each step, update the plan file:
1. Mark the step as complete [x]
2. Add any learnings discovered

Key rules:
- TDD: write tests before implementation
- Each pipeline step is a sub-project with generator/trainer/analyzer
- Plans describe WHAT to do, not include code
- Use subagents for independent work
- JSON input/output between steps
- Python primary, Swift only for OCR
```

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

- [ ] **Session 4: Code review of Session 3**
  - Review Swift CLI: is it truly standalone? Does the Package.swift build cleanly in isolation?
  - Review Python wrapper: error handling, subprocess management, JSON parsing robustness
  - Verify the analyzer can be invoked as a CLI (`python -m ocr_analyzer image.png`)
  - Check that the output schema matches the design document's OCR output format
  - Run integration tests — do they pass on a real macOS machine?
  - Update plan with any issues found

- [ ] **Session 5: OCR generator — training data creation**
  - Create `pipeline/ocr/generator/` package
  - Build the generator that creates labeled OCR test data:
    - **Programmatic generation**: Use Pillow to render text at various sizes (8px–72px), fonts (system fonts available on macOS), colors, and backgrounds. Ground truth is the known rendered text + bounds
    - **VM-based generation**: Use `guivision` to launch apps in VMs, capture screenshots, and use `guivision find-text` output as baseline. This tests the analyzer against real-world rendering
  - Generator CLI: `python -m ocr_generator --output-dir data/ocr/ --count N --mode programmatic|vm`
  - Output format: `data/ocr/samples/` with images + `data/ocr/ground_truth/` with JSON ground truth files using the `GroundTruth` type from common
  - Write tests:
    - Test that programmatic generation creates valid image + ground truth pairs
    - Test that ground truth files conform to the `GroundTruth` schema
    - Test idempotent generation (same seed → same output)

- [ ] **Session 6: OCR trainer/evaluator — accuracy benchmarking**
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

- [ ] **Session 7: Code review of Sessions 5-6 + end-to-end OCR validation**
  - Review generator: does it produce diverse, representative training data?
  - Review evaluator: are the metrics meaningful? Are thresholds reasonable?
  - Run the full OCR pipeline end-to-end: generate data → run analyzer → evaluate → check thresholds
  - Verify the generator/trainer/analyzer pattern is clean and replicable for future steps
  - Document any patterns or utilities that should be extracted to common
  - Retrospective: is the sub-project structure working? Any friction points?
  - Update plan with learnings

### Phase 2: Region Decomposition

- [ ] **Session 8: Geometric region decomposition**
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

- [ ] **Session 9: Code review of Session 8**
  - Review geometric analysis accuracy on real screenshots (capture a few from VMs)
  - Evaluate containment hierarchy quality
  - Check performance on large screenshots (4K resolution)
  - Update plan

- [ ] **Session 10: Region decomposition generator + semantic classifier training**
  - Build generator: launch multi-panel apps (Xcode, VS Code, terminals with splits) in VMs
  - Use accessibility trees as ground truth for region boundaries and semantics
  - Define semantic labels: editor_pane, sidebar, tab_bar, status_bar, toolbar, gutter, content_area, dialog, popup
  - Train initial YOLO model for semantic region classification
  - Evaluator: measure IoU accuracy (geometric) and classification accuracy (semantic) independently
  - Write tests for generator output format and evaluator metrics

- [ ] **Session 11: Code review of Session 10 + region decomposition end-to-end**
  - Review training data diversity — are all semantic categories well-represented?
  - Evaluate model accuracy — does it meet minimum thresholds?
  - Test on screenshots from all three platforms
  - Research note: document findings on recursive refinement (does re-running on sub-regions help?)
  - Update plan

### Phase 3: Widget Detection + State

- [ ] **Session 12: Widget detection baseline**
  - Create `pipeline/widget-detection/` sub-project structure
  - Implement heuristic baseline widget detector (port concepts from Redraw's `tier1/detector.py` and `tier2/classifier.py`)
  - Define widget type taxonomy: button, text_field, checkbox, radio, toggle, slider, dropdown, tab, list_item, tree_item, menu_item, toolbar, scroll_bar, progress_bar, label, link, image, separator
  - Define state properties: enabled/disabled, focused/unfocused, checked/unchecked, selected/unselected, expanded/collapsed, pressed/normal
  - Analyzer CLI: accepts region crop + optional OCR data, outputs widget type + state
  - Write tests with synthetic widget images

- [ ] **Session 13: Code review of Session 12**

- [ ] **Session 14: Widget detection generator + model training**
  - Build cross-platform generator: open apps on macOS, Windows, Linux VMs
  - Use accessibility trees for ground truth (widget type from role, state from attributes)
  - Manipulate widget states programmatically (disable buttons, check checkboxes, focus fields)
  - Capture before/after pairs for state detection training
  - Train per-platform YOLO models
  - Evaluate type accuracy and state accuracy independently
  - Write tests for generator and evaluator

- [ ] **Session 15: Code review of Session 14 + widget detection end-to-end**
  - Cross-platform accuracy comparison
  - Research note: single model vs per-platform models — which performs better?
  - Update plan

### Phase 4: Visual Properties + Font Detection

- [ ] **Session 16: Visual properties — port from Redraw**
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

- [ ] **Session 17: Code review of Session 16**
  - Verify ported code produces identical results to Redraw's originals on the same inputs
  - Benchmark accuracy on real UI element crops
  - Update plan

- [ ] **Session 18: Font detection**
  - Create `pipeline/font-detection/` sub-project structure
  - Port Redraw's `font_matcher.py` (SSIM-based font matching)
  - Build font reference database for system fonts (macOS: SF Pro, SF Mono, Menlo, Helvetica Neue; cross-platform web fonts: Inter, Roboto, etc.)
  - Analyzer: accepts text region crop + OCR result, outputs font family, weight, size, style
  - Generator: render known text in known fonts at known sizes using platform-native rendering
  - Evaluator: measure per-property accuracy (family match rate, size error distribution, weight confusion matrix)
  - Write tests for each property detection independently

- [ ] **Session 19: Code review of Sessions 17-18 + visual properties end-to-end**
  - Validate visual property extraction on real UI elements
  - Validate font detection accuracy across font families and sizes
  - Document minimum reliable font size for family identification
  - Update plan

### Phase 5: Icon Classification + Layout Analysis

- [ ] **Session 20: Icon classification**
  - Create `pipeline/icon-classification/` sub-project structure
  - Define icon taxonomy from design doc: close, minimize, maximize, add, remove, settings, search, menu, chevron, etc.
  - Generator: render icons from SVG sources at various sizes and color schemes; also capture real icons from apps in VMs
  - Train CNN or YOLO-cls classifier
  - Add color-state detection (icon color → semantic state: active, inactive, error, warning)
  - Evaluator: per-icon-type precision/recall
  - Write tests

- [ ] **Session 21: Code review of Session 20**

- [ ] **Session 22: Layout analysis**
  - Create `pipeline/layout-analysis/` sub-project structure
  - Implement primarily algorithmic analysis (geometry, not ML):
    - Spacing measurement between adjacent elements
    - Alignment detection (shared edges, centers, baselines)
    - Grid conformance testing (8px grid, 4px grid, etc.)
    - Distribution analysis (even spacing, justify patterns)
    - Element grouping by proximity
  - Analyzer CLI: accepts list of detected elements with bounding boxes, outputs spatial relationships
  - Generator: create layouts with known spacing/alignment via Playwright or native apps with known layouts
  - Write tests with synthetic element arrangements where expected spacing/alignment is known

- [ ] **Session 23: Code review of Sessions 21-22 + Phase 5 end-to-end**
  - Icon classification accuracy review
  - Layout analysis accuracy on real app screenshots
  - Integration test: full pipeline so far (OCR → region → widget → visual props → layout) on real screenshots
  - Update plan

### Phase 6: WebView Connector + Integration

- [ ] **Session 24: WebView connector**
  - Create `pipeline/webview-connector/` sub-project (does NOT follow generator/trainer/analyzer pattern — it's a discovery/connector tool)
  - Implement CDP discovery for Electron, CEF apps
  - Implement accessibility-based WebView detection (`AXWebArea` on macOS)
  - Implement app-profile-based WebView location
  - Connector CLI: accepts window/process identifier, outputs WebView bounds + CDP endpoint if available
  - Write tests with mock CDP endpoints

- [ ] **Session 25: Code review of Session 24**

- [ ] **Session 26: Pipeline orchestrator + full integration**
  - Build a pipeline orchestrator that composes steps:
    - Sequential composition (OCR → font detection)
    - Selective composition (run only specified steps)
    - Handle recursive/iterative flows (widget detection triggering re-OCR on crops)
  - Orchestrator CLI: `python -m pipeline_orchestrator image.png --steps ocr,regions,widgets,visual-props --output result.json`
  - Full integration tests: run complete pipeline on screenshots from all three platforms
  - Benchmark suite: timing per step, end-to-end latency, accuracy per step
  - Write tests for orchestrator logic (step ordering, dependency resolution, error propagation)

- [ ] **Session 27: Code review of Session 26 + final validation**
  - Review orchestrator design — is composition flexible enough?
  - Run full pipeline on diverse real-world screenshots
  - Performance review: identify bottlenecks
  - Final accuracy report across all steps
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

## Learnings

### Session 1
- Direct port from `guivision_common` to `pipeline_common` was clean — the original types are well-designed
- 49 tests across 7 test files, all passing
- `PipelineStepResult` kept intentionally simple: flat dataclass with `Any` output payload since each step produces different data structures (list of OCR detections, region tree, widget classification, etc.)
- `StepConfig` is a minimal frozen dataclass (step_name + version) — step-specific configs will extend it in their own packages
- uv workspace pattern works well: `uv sync --all-packages` needed to install workspace member dependencies (not just `uv sync`)
- The hatchling `packages = ["src/pipeline_common"]` pattern from the original project carries over unchanged

### Session 2
- Port is correct and complete — all logic, algorithms, and behavior are identical to originals (modulo namespace rename)
- 3 fixes applied: (1) restored `GroundTruthSource` inline comments documenting design intent for each enum member, (2) made `PipelineStepResult` frozen for immutability consistency with `StepConfig`, (3) added `StepConfig` round-trip JSON test
- 50 tests now (was 49), all passing
- `__init__.py` exports all 15 public symbols correctly
- Reviewer flagged missing `Path` import in test_image_io.py — false positive, original had dead imports (`tempfile`, `Path`), port correctly removed them
- Reviewer flagged `output: Any` serialization concern — intentional design choice, tests already document the JSON-native contract via `test_output_can_be_any_json_serializable_type`
- Design note for Session 26 (orchestrator): `PipelineStepResult` may need `status`/`error` fields for failure propagation, and upstream provenance tracking for step composition chains

### Session 3
- Swift CLI extracted cleanly — `recognizeText()` from `FindTextCommand.swift` was self-contained, only needed Vision + CoreGraphics frameworks
- Binary naming convention established: `guivision-` prefix for all pipeline binaries (e.g., `guivision-ocr`). Designed for eventual homebrew bottle installation on PATH
- Binary lookup: PATH first (installed), then relative `.build/debug/` fallback (development)
- `PipelineStepResult.output` stores JSON-native dicts (not typed Detection objects) per the established convention. `parse_ocr_output()` provides typed access when needed
- Swift output format `{text, bounds: {x, y, width, height}}` converts to Detection format `{label, bbox: [x1, y1, x2, y2]}` — the Python wrapper handles this mapping
- 11 unit tests (mocked subprocess) + 8 integration tests (real Swift CLI on Pillow-generated images), all passing
- Apple Vision OCR works well on programmatically rendered text at 36px+ — good confidence scores (>0.9) on clean white/black images
- `python -m ocr_analyzer image.png` CLI works for standalone invocation
- Directory structure: `pipeline/ocr/swift/` for Swift CLI, `pipeline/ocr/src/ocr_analyzer/` for Python wrapper — slightly different from plan's `analyzer/swift/` but cleaner as a Python package
