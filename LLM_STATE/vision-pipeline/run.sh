#!/bin/zsh
# Vision Pipeline — GUIVisionVMDriver
# Usage: ./run.sh
# Exit each phase with /exit to advance. Ctrl+C to stop the cycle.

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../.." && pwd)"

while true; do
  # Phase 1: WORK
  echo "\n=== WORK PHASE ==="
  (cd "$PROJECT" && claude "Read LLM_INSTRUCTIONS.md for project context, then read
LLM_CONTEXT/backlog-plan.md for the phase cycle spec (focus on Phase 1: WORK).

Read LLM_STATE/vision-pipeline/plan.md for the task backlog.
Read LLM_STATE/vision-pipeline/memory.md for distilled learnings.

Pick one task, implement it, record results in plan.md, append a session log
entry to LLM_STATE/vision-pipeline/session-log.md, then stop.

Key commands:
- pytest — run all tests (TDD: write tests first)
- Python primary, Swift only for Apple Vision OCR
- Start VMs: source scripts/macos/vm-start.sh
- Stop VMs: source scripts/macos/vm-stop.sh
- uv sync --all-packages — install all workspace dependencies

Constraints:
- TDD: write tests before implementation
- Each pipeline step is a sub-project with generator/trainer/analyzer
- JSON input/output between steps
- Python primary, Swift only for OCR
- Actually generate data, train models, and evaluate against real VMs — do not proceed with mocks only
- OCR accuracy research continues separately in LLM_STATE/ocr-accuracy/")

  # Phase 2: REFLECT
  echo "\n=== REFLECT PHASE ==="
  (cd "$PROJECT" && claude "Read LLM_CONTEXT/backlog-plan.md for the phase cycle spec
(focus on Phase 2: REFLECT).

Read LLM_STATE/vision-pipeline/session-log.md — focus on the latest entry.
Read LLM_STATE/vision-pipeline/memory.md — the current distilled learnings.

Distill learnings from the latest session into memory.md: add new entries,
sharpen existing ones, remove redundant or outdated ones. Then stop.")

  # Phase 3: TRIAGE
  echo "\n=== TRIAGE PHASE ==="
  (cd "$PROJECT" && claude "Read LLM_CONTEXT/backlog-plan.md for the phase cycle spec
(focus on Phase 3: TRIAGE).

Read LLM_STATE/vision-pipeline/plan.md for the task backlog.
Read LLM_STATE/vision-pipeline/memory.md for distilled learnings.

Review the backlog: reprioritize, split, add, or remove tasks based on current
learnings. If learnings affect sibling plans (e.g. LLM_STATE/ocr-accuracy/),
add backlog entries there rather than duplicating memories. Then stop.")

  echo "\n--- Cycle complete. Enter to continue, Ctrl+C to stop ---"
  read
done
