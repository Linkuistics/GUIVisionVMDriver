"""Integration tests — run the real guivision-ocr Swift CLI on generated test images.

These tests are marked as 'integration' and skipped by default (see pyproject.toml addopts).
Run with: uv run pytest -m integration ocr/tests/test_ocr_integration.py -v
"""

import json
import shutil
from pathlib import Path

import pytest
from PIL import Image, ImageDraw, ImageFont

from ocr_analyzer.analyzer import analyze_image, parse_ocr_output, OCRConfig
from pipeline_common import Detection, PipelineStepResult

BINARY_NAME = "guivision-ocr"

# GUI-realistic font sizes: menu/label text (13px), body text (11-12px), small captions (9px)
RETINA_SCALE = 2

# Preferred fonts in order — SF Mono for code, SF Pro for UI, Helvetica as fallback
FONT_PATHS = [
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def swift_cli_available() -> bool:
    """Check if guivision-ocr binary is available (PATH or dev build)."""
    if shutil.which(BINARY_NAME):
        return True
    dev_binary = Path(__file__).resolve().parent.parent / "swift" / ".build" / "debug" / BINARY_NAME
    return dev_binary.exists()


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not swift_cli_available(), reason="guivision-ocr binary not built"),
]


def _load_font(point_size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """Load the best available system font at the given point size, scaled for Retina."""
    scaled = point_size * RETINA_SCALE
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, scaled)
    return ImageFont.load_default()


def create_text_image(
    text: str, font_size: int = 13, width: int = 400, padding: int = 10,
) -> Image.Image:
    """Create a Retina-scaled white image with black text at a GUI-realistic size.

    font_size is in points (as a GUI app would specify). The image is rendered at 2x
    to match macOS Retina screenshots, so a 13pt font produces 26px glyphs in the image.
    """
    font = _load_font(font_size)
    scaled_width = width * RETINA_SCALE
    scaled_padding = padding * RETINA_SCALE

    # Measure text to size the image height
    dummy = Image.new("RGB", (1, 1))
    bbox = ImageDraw.Draw(dummy).textbbox((0, 0), text, font=font)
    text_height = bbox[3] - bbox[1]

    img_height = text_height + scaled_padding * 2
    img = Image.new("RGB", (scaled_width, img_height), color="white")
    ImageDraw.Draw(img).text((scaled_padding, scaled_padding), text, fill="black", font=font)
    return img


class TestOCRIntegration:
    def test_detects_menu_bar_text(self, tmp_path):
        """13pt — standard macOS menu bar / button label size."""
        img = create_text_image("File Edit View", font_size=13)
        image_path = tmp_path / "menu.png"
        img.save(image_path)

        result = analyze_image(image_path)

        assert isinstance(result, PipelineStepResult)
        assert result.step_name == "ocr"
        assert len(result.output) > 0

        texts = [d["label"].lower() for d in result.output]
        combined = " ".join(texts)
        assert "file" in combined
        assert "edit" in combined

    def test_detects_body_text(self, tmp_path):
        """11pt — common body/list text in macOS apps."""
        img = create_text_image("Save As...", font_size=11)
        image_path = tmp_path / "body.png"
        img.save(image_path)

        result = analyze_image(image_path)
        texts = [d["label"].lower() for d in result.output]
        combined = " ".join(texts)
        assert "save" in combined

    def test_detects_small_caption_text(self, tmp_path):
        """9pt — small captions, status bar text."""
        img = create_text_image("127.0.0.1:8080", font_size=9)
        image_path = tmp_path / "caption.png"
        img.save(image_path)

        result = analyze_image(image_path)
        texts = [d["label"] for d in result.output]
        combined = " ".join(texts)
        assert "127" in combined

    def test_detects_multiple_lines(self, tmp_path):
        """Two lines of 12pt text spaced apart."""
        font = _load_font(12)
        scaled_width = 400 * RETINA_SCALE
        img = Image.new("RGB", (scaled_width, 120 * RETINA_SCALE), color="white")
        draw = ImageDraw.Draw(img)
        draw.text((20 * RETINA_SCALE, 15 * RETINA_SCALE), "First Line", fill="black", font=font)
        draw.text((20 * RETINA_SCALE, 65 * RETINA_SCALE), "Second Line", fill="black", font=font)
        image_path = tmp_path / "multiline.png"
        img.save(image_path)

        result = analyze_image(image_path)
        texts = [d["label"].lower() for d in result.output]
        combined = " ".join(texts)
        assert "first" in combined
        assert "second" in combined

    def test_output_has_valid_bounding_boxes(self, tmp_path):
        img = create_text_image("Testing OCR", font_size=13, width=300)
        image_path = tmp_path / "bbox_test.png"
        img.save(image_path)

        result = analyze_image(image_path)
        assert len(result.output) > 0

        img_width = 300 * RETINA_SCALE
        img_obj = Image.open(image_path)
        img_height = img_obj.height

        for det in result.output:
            x1, y1, x2, y2 = det["bbox"]
            assert x1 >= 0
            assert y1 >= 0
            assert x2 > x1, "x2 must be greater than x1"
            assert y2 > y1, "y2 must be greater than y1"
            assert x2 <= img_width, f"bbox x2 ({x2}) exceeds image width ({img_width})"
            assert y2 <= img_height, f"bbox y2 ({y2}) exceeds image height ({img_height})"

    def test_confidence_values_are_reasonable(self, tmp_path):
        img = create_text_image("Confidence Test", font_size=13)
        image_path = tmp_path / "confidence.png"
        img.save(image_path)

        result = analyze_image(image_path)
        for det in result.output:
            assert 0.0 <= det["confidence"] <= 1.0

    def test_result_round_trips_through_json(self, tmp_path):
        img = create_text_image("JSON Test", font_size=12)
        image_path = tmp_path / "json_test.png"
        img.save(image_path)

        result = analyze_image(image_path)
        json_str = json.dumps(result.to_dict())
        restored = PipelineStepResult.from_dict(json.loads(json_str))
        assert restored.output == result.output

    def test_parse_ocr_output_returns_typed_detections(self, tmp_path):
        img = create_text_image("Typed Access", font_size=13)
        image_path = tmp_path / "typed.png"
        img.save(image_path)

        result = analyze_image(image_path)
        detections = parse_ocr_output(result)
        assert all(isinstance(d, Detection) for d in detections)
        if detections:
            assert isinstance(detections[0].label, str)
            assert detections[0].bbox.width > 0

    def test_fast_recognition_level(self, tmp_path):
        img = create_text_image("Fast Mode", font_size=14)
        image_path = tmp_path / "fast.png"
        img.save(image_path)

        config = OCRConfig(recognition_level="fast")
        result = analyze_image(image_path, config=config)

        assert isinstance(result, PipelineStepResult)
        texts = [d["label"].lower() for d in result.output]
        combined = " ".join(texts)
        assert "fast" in combined

    def test_empty_image_returns_no_detections(self, tmp_path):
        """A blank white image should produce no text detections."""
        img = Image.new("RGB", (200, 200), color="white")
        image_path = tmp_path / "blank.png"
        img.save(image_path)

        result = analyze_image(image_path)
        assert result.output == []
