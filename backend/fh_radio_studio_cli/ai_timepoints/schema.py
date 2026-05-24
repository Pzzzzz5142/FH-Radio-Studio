from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

SCHEMA_VERSION = 2
WRITE_SAMPLE_RATE = 48000


@dataclass
class ProviderStatus:
    name: str
    status: str
    version: Optional[str] = None
    device: Optional[str] = None
    runtime_ms: int = 0
    warnings: List[str] = field(default_factory=list)

    def to_json(self) -> Dict[str, object]:
        payload: Dict[str, object] = {
            "name": self.name,
            "status": self.status,
            "runtime_ms": int(self.runtime_ms),
            "warnings": list(self.warnings),
        }
        if self.version:
            payload["version"] = self.version
        if self.device:
            payload["device"] = self.device
        return payload


def point_candidate(
    t: float,
    score: float,
    why: str,
    evidence: Optional[Dict[str, object]] = None,
) -> Dict[str, object]:
    return {
        "t": round(float(t), 3),
        "score": round(float(score), 3),
        "why": why,
        "evidence": evidence or {},
    }


def loop_candidate(
    start: float,
    end: float,
    score: float,
    bars: int,
    why: str,
    evidence: Optional[Dict[str, object]] = None,
) -> Dict[str, object]:
    return {
        "start": round(float(start), 3),
        "end": round(float(end), 3),
        "score": round(float(score), 3),
        "bars": int(bars),
        "why": why,
        "evidence": evidence or {},
    }


def clamp_time(value: float, duration: float) -> float:
    if duration <= 0:
        return 0.0
    return max(0.0, min(float(value), float(duration)))
