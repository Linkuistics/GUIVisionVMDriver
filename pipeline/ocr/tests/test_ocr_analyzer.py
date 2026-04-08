import json
from unittest.mock import patch

import pytest

from ocr_analyzer.analyzer import analyze_image, parse_ocr_output, OCRConfig
from pipeline_common import BoundingBox, Detection, PipelineStepResult


SAMPLE_SWIFT_OUTPUT = json.dumps([
    {
        "text": "Save",
        "bounds": {"x": 100.0, "y": 50.0, "width": 60.0, "height": 20.0},
        "confidence": 0.95,
    },
    {
        "text": "Cancel",
        "bounds": {"x": 200.0, "y": 50.0, "width": 80.0, "height": 20.0},
        "confidence": 0.88,
    },
])


class TestAnalyzeImage:
    def _mock_subprocess_success(self, stdout: str, returncode: int = 0):
        """Create a mock CompletedProcess with given stdout."""
        from unittest.mock import MagicMock

        result = MagicMock()
        result.returncode = returncode
        result.stdout = stdout
        result.stderr = ""
        return result

    def test_returns_pipeline_step_result(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        assert isinstance(result, PipelineStepResult)
        assert result.step_name == "ocr"
        assert result.version == "0.1.0"
        assert result.elapsed_seconds >= 0.0

    def test_output_contains_detection_dicts(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        assert len(result.output) == 2
        assert all(isinstance(d, dict) for d in result.output)
        assert result.output[0]["label"] == "Save"
        assert result.output[0]["bbox"] == [100, 50, 160, 70]

    def test_detection_fields_converted_correctly(self, tmp_path):
        """Swift bounds {x, y, width, height} convert to Detection bbox [x1, y1, x2, y2]."""
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        first = result.output[0]
        assert first["label"] == "Save"
        assert first["confidence"] == pytest.approx(0.95)
        assert first["bbox"] == [100, 50, 160, 70]

        second = result.output[1]
        assert second["label"] == "Cancel"
        assert second["confidence"] == pytest.approx(0.88)
        assert second["bbox"] == [200, 50, 280, 70]

    def test_input_metadata_contains_image_path(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        assert result.input_metadata["image_path"] == str(image_path)

    def test_empty_ocr_output(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success("[]")
            result = analyze_image(image_path)

        assert result.output == []

    def test_custom_config_passed_to_cli(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")
        config = OCRConfig(recognition_level="fast", languages="en,de", min_confidence=0.8)

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success("[]")
            analyze_image(image_path, config=config)

        call_args = mock_run.call_args[0][0]
        assert "--recognition-level" in call_args
        assert "fast" in call_args
        assert "--languages" in call_args
        assert "en,de" in call_args
        assert "--min-confidence" in call_args
        assert "0.8" in call_args

    def test_nonexistent_image_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            analyze_image(tmp_path / "nonexistent.png")

    def test_swift_cli_failure_raises(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success("", returncode=1)
            mock_run.return_value.stderr = "Error: Image file not found"
            with pytest.raises(RuntimeError, match="guivision-ocr failed"):
                analyze_image(image_path)

    def test_binary_lookup_checks_path_then_relative(self, tmp_path):
        """When guivision-ocr is not on PATH, falls back to relative build path."""
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run, \
             patch("ocr_analyzer.analyzer.shutil.which", return_value=None):
            mock_run.return_value = self._mock_subprocess_success("[]")
            analyze_image(image_path)

        call_args = mock_run.call_args[0][0]
        # Should use relative build path when not on PATH
        assert call_args[0].endswith("guivision-ocr")

    def test_result_is_json_serializable(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        result_dict = result.to_dict()
        json_str = json.dumps(result_dict)
        restored = PipelineStepResult.from_dict(json.loads(json_str))
        assert restored.output == result.output


class TestParseOCROutput:
    """Test the typed accessor for converting output dicts back to Detection objects."""

    def test_parse_detections_from_result(self, tmp_path):
        image_path = tmp_path / "test.png"
        image_path.write_bytes(b"fake-png-data")

        with patch("ocr_analyzer.analyzer.subprocess.run") as mock_run:
            mock_run.return_value = self._mock_subprocess_success(SAMPLE_SWIFT_OUTPUT)
            result = analyze_image(image_path)

        detections = parse_ocr_output(result)
        assert len(detections) == 2
        assert all(isinstance(d, Detection) for d in detections)
        assert detections[0].label == "Save"
        assert detections[0].bbox == BoundingBox(x1=100, y1=50, x2=160, y2=70)

    def _mock_subprocess_success(self, stdout: str, returncode: int = 0):
        from unittest.mock import MagicMock

        result = MagicMock()
        result.returncode = returncode
        result.stdout = stdout
        result.stderr = ""
        return result
