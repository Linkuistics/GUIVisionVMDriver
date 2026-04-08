import json
from pipeline_common.pipeline_result import PipelineStepResult, StepConfig


class TestStepConfig:
    def test_create(self):
        config = StepConfig(step_name="ocr", version="0.1.0")
        assert config.step_name == "ocr"
        assert config.version == "0.1.0"

    def test_to_dict(self):
        config = StepConfig(step_name="ocr", version="0.1.0")
        d = config.to_dict()
        assert d == {"step_name": "ocr", "version": "0.1.0"}

    def test_from_dict(self):
        config = StepConfig.from_dict({"step_name": "ocr", "version": "0.1.0"})
        assert config.step_name == "ocr"

    def test_roundtrip_json(self):
        config = StepConfig(step_name="region-decomposition", version="0.3.0")
        json_str = json.dumps(config.to_dict())
        restored = StepConfig.from_dict(json.loads(json_str))
        assert restored.step_name == config.step_name
        assert restored.version == config.version


class TestPipelineStepResult:
    def test_create(self):
        result = PipelineStepResult(
            step_name="ocr",
            version="0.1.0",
            elapsed_seconds=1.23,
            input_metadata={"image_path": "screenshot.png", "image_width": 1920, "image_height": 1080},
            output=[{"text": "Save", "bounds": {"x": 34, "y": 14, "width": 60, "height": 20}}],
        )
        assert result.step_name == "ocr"
        assert result.elapsed_seconds == 1.23
        assert result.output[0]["text"] == "Save"

    def test_to_dict(self):
        result = PipelineStepResult(
            step_name="ocr",
            version="0.1.0",
            elapsed_seconds=0.5,
            input_metadata={"image_path": "test.png"},
            output={"detections": []},
        )
        d = result.to_dict()
        assert d["step_name"] == "ocr"
        assert d["version"] == "0.1.0"
        assert d["elapsed_seconds"] == 0.5
        assert d["input_metadata"]["image_path"] == "test.png"
        assert d["output"] == {"detections": []}

    def test_from_dict(self):
        d = {
            "step_name": "region-decomposition",
            "version": "0.2.0",
            "elapsed_seconds": 2.1,
            "input_metadata": {},
            "output": {"regions": []},
        }
        result = PipelineStepResult.from_dict(d)
        assert result.step_name == "region-decomposition"
        assert result.version == "0.2.0"
        assert result.elapsed_seconds == 2.1

    def test_roundtrip_json(self):
        result = PipelineStepResult(
            step_name="widget-detection",
            version="0.1.0",
            elapsed_seconds=3.45,
            input_metadata={"source_step": "ocr", "image_path": "crop.png"},
            output=[{"type": "button", "confidence": 0.93}],
        )
        json_str = json.dumps(result.to_dict())
        restored = PipelineStepResult.from_dict(json.loads(json_str))
        assert restored.step_name == result.step_name
        assert restored.version == result.version
        assert restored.elapsed_seconds == result.elapsed_seconds
        assert restored.input_metadata == result.input_metadata
        assert restored.output == result.output

    def test_output_can_be_any_json_serializable_type(self):
        """Output payload is flexible — list, dict, or primitive."""
        for output in [[], {}, [1, 2, 3], {"key": "value"}, "simple"]:
            result = PipelineStepResult(
                step_name="test",
                version="0.1.0",
                elapsed_seconds=0.0,
                input_metadata={},
                output=output,
            )
            roundtripped = PipelineStepResult.from_dict(result.to_dict())
            assert roundtripped.output == output
