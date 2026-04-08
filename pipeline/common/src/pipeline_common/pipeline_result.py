from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class StepConfig:
    """Base configuration identifying a pipeline step."""

    step_name: str
    version: str

    def to_dict(self) -> dict:
        return {"step_name": self.step_name, "version": self.version}

    @classmethod
    def from_dict(cls, d: dict) -> StepConfig:
        return cls(step_name=d["step_name"], version=d["version"])


@dataclass(frozen=True)
class PipelineStepResult:
    """Standard envelope wrapping every pipeline step's output.

    Carries enough metadata for composition (downstream steps know what produced this),
    debugging (timing, input metadata), and reproducibility (step name + version).
    """

    step_name: str
    version: str
    elapsed_seconds: float
    input_metadata: dict[str, Any]
    output: Any

    def to_dict(self) -> dict:
        return {
            "step_name": self.step_name,
            "version": self.version,
            "elapsed_seconds": self.elapsed_seconds,
            "input_metadata": self.input_metadata,
            "output": self.output,
        }

    @classmethod
    def from_dict(cls, d: dict) -> PipelineStepResult:
        return cls(
            step_name=d["step_name"],
            version=d["version"],
            elapsed_seconds=d["elapsed_seconds"],
            input_metadata=d["input_metadata"],
            output=d["output"],
        )
