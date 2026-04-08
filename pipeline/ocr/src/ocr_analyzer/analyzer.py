from __future__ import annotations

import json
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from pipeline_common import BoundingBox, Detection, PipelineStepResult

BINARY_NAME = "guivision-ocr"
STEP_NAME = "ocr"
VERSION = "0.1.0"


@dataclass(frozen=True)
class OCRConfig:
    """Configuration for the OCR analyzer step."""

    recognition_level: str = "accurate"
    languages: str = "en"
    min_confidence: float = 0.5


def _find_binary() -> str:
    """Find the guivision-ocr binary: check PATH first, then known build path."""
    on_path = shutil.which(BINARY_NAME)
    if on_path:
        return on_path

    # Development fallback: relative to this package's location
    # pipeline/ocr/src/ocr_analyzer/analyzer.py -> pipeline/ocr/swift/.build/debug/guivision-ocr
    package_dir = Path(__file__).resolve().parent
    dev_binary = package_dir.parent.parent / "swift" / ".build" / "debug" / BINARY_NAME
    if dev_binary.exists():
        return str(dev_binary)

    raise FileNotFoundError(
        f"{BINARY_NAME} not found on PATH or at {dev_binary}. "
        f"Build it with: cd pipeline/ocr/swift && swift build"
    )


def _swift_output_to_detection_dict(entry: dict) -> dict:
    """Convert a Swift CLI output entry to a Detection-compatible dict.

    Swift outputs: {text, bounds: {x, y, width, height}, confidence}
    Detection dict: {label, bbox: [x1, y1, x2, y2], confidence}
    """
    bounds = entry["bounds"]
    x1 = int(bounds["x"])
    y1 = int(bounds["y"])
    x2 = int(bounds["x"] + bounds["width"])
    y2 = int(bounds["y"] + bounds["height"])

    return {
        "label": entry["text"],
        "bbox": [x1, y1, x2, y2],
        "confidence": entry["confidence"],
    }


def analyze_image(
    image_path: str | Path,
    config: OCRConfig | None = None,
) -> PipelineStepResult:
    """Run OCR on an image and return a PipelineStepResult.

    The output field contains a list of detection dicts, each with:
    - label: the recognized text
    - bbox: [x1, y1, x2, y2] in pixel coordinates
    - confidence: float 0.0-1.0
    """
    image_path = Path(image_path)
    if not image_path.exists():
        raise FileNotFoundError(f"Image not found: {image_path}")

    if config is None:
        config = OCRConfig()

    binary = _find_binary()

    cmd = [
        binary,
        str(image_path),
        "--recognition-level", config.recognition_level,
        "--languages", config.languages,
        "--min-confidence", str(config.min_confidence),
    ]

    start = time.monotonic()
    result = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.monotonic() - start

    if result.returncode != 0:
        raise RuntimeError(
            f"guivision-ocr failed (exit {result.returncode}): {result.stderr.strip()}"
        )

    raw_detections = json.loads(result.stdout)
    detection_dicts = [_swift_output_to_detection_dict(entry) for entry in raw_detections]

    return PipelineStepResult(
        step_name=STEP_NAME,
        version=VERSION,
        elapsed_seconds=elapsed,
        input_metadata={"image_path": str(image_path)},
        output=detection_dicts,
    )


def parse_ocr_output(result: PipelineStepResult) -> list[Detection]:
    """Convert a PipelineStepResult from the OCR step into typed Detection objects."""
    return [Detection.from_dict(d) for d in result.output]
