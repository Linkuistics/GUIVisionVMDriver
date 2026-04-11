Read LLM_INSTRUCTIONS.md for project context, then read
LLM_CONTEXT/backlog-plan.md for the phase cycle spec (focus on Phase 1: WORK).

Read LLM_STATE/vision-pipeline/backlog.md for the task backlog.
Read LLM_STATE/vision-pipeline/memory.md for distilled learnings.

Display a summary of the current backlog (title, status, and priority for each
task). Then ask the user if they have any input on which task to work on next.
Wait for the user's response. If they have a preference, work on that task;
otherwise pick the best next task.

Implement it, record results in backlog.md, append a session log entry to
LLM_STATE/vision-pipeline/session-log.md.
Write reflect to LLM_STATE/vision-pipeline/phase.md, then stop.

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
- OCR accuracy research continues separately in LLM_STATE/ocr-accuracy/
