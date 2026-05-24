from __future__ import annotations

from typing import Dict, List

from ..schema import clamp_time, loop_candidate


def _bars_for_length(start: float, end: float, beat_step: float) -> int:
    if beat_step <= 0:
        return 1
    return max(1, min(128, round((end - start) / beat_step / 4)))


def build_loop_candidates(
    base_start: float,
    base_end: float,
    duration: float,
    beat_step: float,
    label: str,
    provider: str,
) -> List[Dict[str, object]]:
    one_bar = beat_step * 4
    variants = [
        (0.0, 0.0, 0.60, f"{label} · fallback loop pair"),
        (one_bar, 0.0, 0.50, "入口后移 1 小节"),
        (0.0, -one_bar, 0.48, "出口前移 1 小节"),
        (one_bar * 2, 0.0, 0.42, "入口后移 2 小节"),
        (0.0, -one_bar * 2, 0.40, "出口前移 2 小节"),
    ]
    candidates: List[Dict[str, object]] = []
    seen: set[tuple[float, float]] = set()
    for start_offset, end_offset, score, why in variants:
        start = clamp_time(base_start + start_offset, duration)
        end = clamp_time(base_end + end_offset, duration)
        if end <= start + 0.5:
            end = clamp_time(start + max(0.5, one_bar * 4), duration)
        if end <= start + 0.5:
            continue
        key = (round(start, 3), round(end, 3))
        if key in seen:
            continue
        seen.add(key)
        candidates.append(
            loop_candidate(
                start,
                end,
                score,
                _bars_for_length(start, end, beat_step),
                why,
                {
                    "providers": [provider],
                    "quality": "fallback",
                    "end_to_start_preview": True,
                    "seam_similarity": None,
                    "vocal_cut_risk": None,
                },
            )
        )
    return candidates
