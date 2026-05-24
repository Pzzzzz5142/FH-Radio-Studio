from __future__ import annotations

from typing import Dict, Iterable, List

_MIN_POST_LOOP_SECONDS = 20.0


def sort_candidates(
    candidates: Iterable[Dict[str, object]], limit: int = 5
) -> List[Dict[str, object]]:
    return sort_point_candidates(candidates, limit=limit)


def sort_point_candidates(
    candidates: Iterable[Dict[str, object]], limit: int = 5
) -> List[Dict[str, object]]:
    return sorted(
        candidates,
        key=lambda item: float(item.get("score", 0.0)),
        reverse=True,
    )[:limit]


def sort_track_loop_candidates(
    candidates: Iterable[Dict[str, object]], limit: int = 5
) -> List[Dict[str, object]]:
    return sorted(
        candidates,
        key=lambda item: (
            float(item.get("score", 0.0)),
            _loop_bars(item),
            _loop_duration(item),
        ),
        reverse=True,
    )[:limit]


def sort_post_loop_candidates(
    candidates: Iterable[Dict[str, object]], limit: int = 8
) -> List[Dict[str, object]]:
    items = list(candidates)
    valid_length_items = [
        item for item in items if _loop_duration(item) + 1e-6 >= _MIN_POST_LOOP_SECONDS
    ]
    if valid_length_items:
        items = valid_length_items
    return sorted(
        items,
        key=lambda item: (
            float(item.get("score", 0.0)),
            _post_loop_chorus_overlap(item),
            _post_loop_bar_fit(item),
            -_loop_duration(item),
        ),
        reverse=True,
    )[:limit]


def _loop_bars(item: Dict[str, object]) -> float:
    return float(item.get("bars", 0.0)) if "start" in item and "end" in item else 0.0


def _loop_duration(item: Dict[str, object]) -> float:
    if "start" not in item or "end" not in item:
        return 0.0
    duration = float(item.get("end", 0.0)) - float(item.get("start", 0.0))
    return duration


def _post_loop_bar_fit(item: Dict[str, object]) -> float:
    return -abs(_loop_bars(item) - 8.0)


def _post_loop_chorus_overlap(item: Dict[str, object]) -> float:
    evidence = dict(item.get("evidence") or {})
    return float(evidence.get("post_loop_chorus_overlap", 0.0) or 0.0)
