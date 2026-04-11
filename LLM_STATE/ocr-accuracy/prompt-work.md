Read LLM_INSTRUCTIONS.md for project context, then read
../LLM_CONTEXT/backlog-plan.md for the phase cycle spec (focus on Phase 1: WORK).

Read LLM_STATE/ocr-accuracy/backlog.md for the hypothesis backlog and current baseline.
Read LLM_STATE/ocr-accuracy/memory.md for distilled learnings.

Display a summary of the current backlog (title, status, and priority for each
hypothesis). Then ask the user if they have any input on which hypothesis to
work on next. Wait for the user's response. If they have a preference, work on
that one; otherwise pick the best next hypothesis.

Implement it, evaluate against baseline, record results in backlog.md, append a
session log entry to LLM_STATE/ocr-accuracy/session-log.md.
Write reflect to LLM_STATE/ocr-accuracy/phase.md, then stop.

Research cycle:
1. REVIEW previous findings and current baseline metrics
2. DECIDE what to try next — pick from the backlog, modify based on learnings,
   or propose a new approach. Explain your reasoning.
3. IMPLEMENT the change (TDD — write tests first)
4. GENERATE + EVALUATE:
   - Start VM: source scripts/macos/vm-start.sh
   - Update pipeline/connect.json with VNC port, password, agent IP from startup output
   - Kill any stale guivision _server processes before starting
   - Generate: cd pipeline && uv run python -m ocr_generator --connect-json connect.json
     --output-dir data/ocr-vm --guivision-binary ../cli/macos/.build/debug/guivision
   - Analyze each sample: uv run python -m ocr_analyzer <image>
   - Evaluate with BOTH strategies:
     uv run python -m ocr_evaluator evaluate --data-dir data/ocr-vm --matching-strategy text_content --output data/ocr-vm/results-text.json
     uv run python -m ocr_evaluator evaluate --data-dir data/ocr-vm --matching-strategy iou --output data/ocr-vm/results-iou.json
   - Compare per-app and aggregate against baseline
5. REFLECT — what worked, what didn't, what does this suggest trying next?
6. UPDATE backlog.md: record results, add/reprioritize hypotheses, update baseline if improved
7. Stop VM: source scripts/macos/vm-stop.sh

Key rules:
- TDD: write tests before implementation
- Kill stale guivision _server processes before VM operations
- OCR analyzer outputs PipelineStepResult envelopes — unwrap output field
- Always evaluate and report both IoU and text-content matching
- Run uv run pytest --ignore=ocr/swift -x before and after changes
- After completing the cycle, run all pipeline tests to confirm 540+ tests pass
- Evaluate on all three platforms: source scripts/macos/vm-start.sh --platform {macos|linux|windows}
- The generator auto-detects platform from connect.json's platform field
