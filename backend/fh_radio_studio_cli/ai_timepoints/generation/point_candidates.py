from __future__ import annotations

from typing import Dict, List

from ..schema import clamp_time, point_candidate


def build_point_candidates(
    base_time: float,
    duration: float,
    beat_step: float,
    marker_name: str,
    label: str,
    provider: str,
) -> List[Dict[str, object]]:
    offsets = [
        (0.0, 0.64, f"{label} · baseline fallback"),
        (-beat_step, 0.52, "提前 1 拍"),
        (beat_step, 0.50, "推后 1 拍"),
        (-beat_step * 4, 0.42, "提前 1 小节"),
        (beat_step * 4, 0.40, "推后 1 小节"),
    ]
    candidates: List[Dict[str, object]] = []
    seen: set[float] = set()
    for offset, score, why in offsets:
        t = round(clamp_time(base_time + offset, duration), 3)
        if t in seen:
            continue
        seen.add(t)
        candidates.append(
            point_candidate(
                t,
                score,
                why,
                {
                    "marker": marker_name,
                    "providers": [provider],
                    "quality": "fallback",
                    "nearest_downbeat_delta_ms": 0 if offset == 0 else None,
                },
            )
        )
    return candidates
