"""CLI entry point: python -m ocr_analyzer image.png [--config ...]"""
from __future__ import annotations

import argparse
import json
import sys

from ocr_analyzer.analyzer import OCRConfig, analyze_image


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ocr_analyzer",
        description="Run OCR on an image and output a PipelineStepResult as JSON",
    )
    parser.add_argument("image_path", help="Path to the input image")
    parser.add_argument(
        "--recognition-level",
        default="accurate",
        choices=["accurate", "fast"],
        help="Apple Vision recognition level (default: accurate)",
    )
    parser.add_argument(
        "--languages", default="en", help="Comma-separated BCP 47 language codes (default: en)"
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=0.5,
        help="Minimum confidence threshold (default: 0.5)",
    )

    args = parser.parse_args()

    config = OCRConfig(
        recognition_level=args.recognition_level,
        languages=args.languages,
        min_confidence=args.min_confidence,
    )

    result = analyze_image(args.image_path, config=config)
    print(json.dumps(result.to_dict(), indent=2))


if __name__ == "__main__":
    main()
