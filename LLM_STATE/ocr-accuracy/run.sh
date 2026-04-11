#!/bin/zsh
# OCR Accuracy Research — GUIVisionVMDriver
# Usage: ./run.sh
# Exit each phase with /exit to advance. Ctrl+C to stop the cycle.

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../.." && pwd)"

while true; do
  # Phase 1: WORK
  echo "\n=== WORK PHASE ==="
  (cd "$PROJECT" && claude "Read LLM_INSTRUCTIONS.md for project context, then read
../LLM_CONTEXT/backlog-plan.md for the phase cycle spec (focus on Phase 1: WORK).

Read LLM_STATE/ocr-accuracy/plan.md for the hypothesis backlog and current baseline.
Read LLM_STATE/ocr-accuracy/memory.md for distilled learnings.

Pick one hypothesis, implement it, evaluate against baseline, record results in
plan.md, append a session log entry to LLM_STATE/ocr-accuracy/session-log.md,
then stop.

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
6. UPDATE plan.md: record results, add/reprioritize hypotheses, update baseline if improved
7. Stop VM: source scripts/macos/vm-stop.sh

Key rules:
- TDD: write tests before implementation
- Kill stale guivision _server processes before VM operations
- OCR analyzer outputs PipelineStepResult envelopes — unwrap output field
- Always evaluate and report both IoU and text-content matching
- Run uv run pytest --ignore=ocr/swift -x before and after changes
- After completing the cycle, run all pipeline tests to confirm 540+ tests pass
- Evaluate on all three platforms: source scripts/macos/vm-start.sh --platform {macos|linux|windows}
- The generator auto-detects platform from connect.json's platform field")

  # Phase 2: REFLECT
  echo "\n=== REFLECT PHASE ==="
  (cd "$PROJECT" && claude "Read ../LLM_CONTEXT/backlog-plan.md for the phase cycle spec
(focus on Phase 2: REFLECT).

Read LLM_STATE/ocr-accuracy/session-log.md — focus on the latest entry.
Read LLM_STATE/ocr-accuracy/memory.md — the current distilled learnings.

Distill learnings from the latest session into memory.md: add new entries,
sharpen existing ones, remove redundant or outdated ones. Then stop.")

  # Phase 3: TRIAGE
  echo "\n=== TRIAGE PHASE ==="
  (cd "$PROJECT" && claude "Read ../LLM_CONTEXT/backlog-plan.md for the phase cycle spec
(focus on Phase 3: TRIAGE).

Read LLM_STATE/ocr-accuracy/plan.md for the hypothesis backlog.
Read LLM_STATE/ocr-accuracy/memory.md for distilled learnings.

Review the backlog: reprioritize, split, add, or remove hypotheses based on
current learnings. If learnings affect sibling plans (e.g. LLM_STATE/vision-pipeline/),
add backlog entries there rather than duplicating memories. Then stop.")

  echo "\n--- Cycle complete. Enter to continue, Ctrl+C to stop ---"
  read
done
