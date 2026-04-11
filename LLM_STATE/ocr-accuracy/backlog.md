# OCR Accuracy Research

Iterative research to improve OCR evaluation accuracy. Each session picks a hypothesis,
implements it, evaluates against the baseline, and updates this document with findings.

## Current Baseline

Established 2026-04-11 (Session 23, after H3b). Multi-platform.

### macOS (10 samples: TextEdit, Terminal, Safari, Finder)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 6.8% | 66.3% |
| Word accuracy | 6.0% | 66.3% |
| Detection F1 | 6.0% | 47.6% |
| Precision | 5.1% | 39.3% |
| Recall | 7.2% | 60.3% |

### Windows (8 samples: Notepad, Windows Terminal, Explorer; Edge skipped)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 9.5% | 20.6% |
| Word accuracy | 9.2% | 20.6% |
| Detection F1 | 8.3% | 24.6% |
| Precision | 13.1% | 33.9% |
| Recall | 6.1% | 19.3% |

### Linux (8 samples: GNOME Text Editor, GNOME Terminal, Nautilus; Firefox skipped)

| Metric | IoU Matching | Text-Content Matching |
|---|---|---|
| Char accuracy | 2.3% | 35.1% |
| Word accuracy | 0.0% | 35.1% |
| Detection F1 | 1.9% | 54.6% |
| Precision | 2.5% | 55.9% |
| Recall | 1.5% | 53.4% |

### Key Remaining Gaps

- **Terminal/TextEdit body text**: AX tree has no per-line text for terminal output or
  editor content. Main remaining gap. These apps have 30+ OCR predictions but only 2-9
  GT elements.
- **OCR merges adjacent items**: "File Edit View" detected as one span — text-content
  matching handles this (word containment) but IoU can't match.

## Task Backlog

### Constructed ground truth for Terminal `[ground-truth]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** AX tree has only 5 structural elements (window chrome). OCR correctly
  finds 32 lines of terminal text (prompt, command output). The ground truth is measuring
  the wrong thing entirely. After typing commands (`ls -la /`, `cal`), construct GT from
  the known command + expected output patterns. Use the typed text and command output as
  GT labels, with bounding boxes estimated from character grid (Terminal uses fixed-width
  font, so row/col maps to pixels).
- **Results:** _pending_

### Constructed ground truth for TextEdit `[ground-truth]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** AX tree concatenates all typed text into one label without line breaks.
  Toolbar labels are descriptions ("bold", "italic", "underline") not visual text. OCR
  correctly reads individual lines. Use the text we type via interactions as GT, split
  into lines. Each line becomes a separate GT detection with bounds estimated from font
  size and line height.
- **Results:** _pending_

### Fuzzy word matching `[matching]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** OCR may misread characters ("Helverica" for "Helvetica"). Current
  whole-word matching requires exact match. Allow near-matches using edit distance
  threshold (e.g., Levenshtein distance <= 1 for words >4 chars).
- **Results:** _pending_

### Word-level OCR detection `[analyzer]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Apple Vision OCR groups nearby text into lines. A single detection
  "TextEdit File Edit View" spans the entire menu bar. This makes IoU matching useless
  and limits spatial precision. Investigate Apple Vision API for word-level bounding
  boxes (VNRecognizedText provides character-level bounds). Modify the Swift CLI to
  output per-word detections.
- **Results:** _pending_

### Confidence threshold tuning `[analyzer]`
- **Status:** not_started
- **Dependencies:** none
- **Description:** Some low-confidence OCR detections may be noise (artifacts, partial
  text). Evaluate precision/recall trade-off at different confidence thresholds (0.3,
  0.5, 0.7, 0.9). Find optimal threshold that improves precision without significant
  recall loss.
- **Results:** _pending_
