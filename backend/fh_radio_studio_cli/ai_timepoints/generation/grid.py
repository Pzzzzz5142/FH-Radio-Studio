from __future__ import annotations

from statistics import median
from typing import Dict, Iterable, List, Optional


def build_grid(duration: float, bpm: float, max_beats: int) -> Dict[str, object]:
    beat_step = 60.0 / bpm if bpm > 0 else 0.5
    count = int(duration / beat_step) + 1 if beat_step > 0 else 0
    count = max(0, min(count, max_beats))
    beats = [round(index * beat_step, 3) for index in range(count)]
    downbeats = beats[::4]
    bars: List[Dict[str, object]] = [
        {"start": start, "index": index + 1, "beats": 4} for index, start in enumerate(downbeats)
    ]
    return {
        "beats": beats,
        "downbeats": downbeats,
        "bars": bars,
        "bpm": float(bpm),
        "beat_step": beat_step,
    }


def build_grid_from_beats(
    beats: Iterable[float],
    downbeats: Optional[Iterable[float]],
    *,
    duration: float,
    max_beats: int,
    fallback_bpm: float,
    provider: str,
) -> Dict[str, object]:
    clean_beats = _clean_times(beats, duration, max_beats)
    clean_downbeats = _clean_times(downbeats or [], duration, max_beats)
    if not clean_beats:
        return build_grid(duration, fallback_bpm, max_beats)

    diffs = [
        clean_beats[index] - clean_beats[index - 1]
        for index in range(1, len(clean_beats))
        if clean_beats[index] > clean_beats[index - 1]
    ]
    beat_step = median(diffs) if diffs else 60.0 / fallback_bpm
    bpm = 60.0 / beat_step if beat_step > 0 else fallback_bpm
    if not clean_downbeats:
        clean_downbeats = clean_beats[::4]
    bars: List[Dict[str, object]] = [
        {"start": start, "index": index + 1, "beats": 4}
        for index, start in enumerate(clean_downbeats)
    ]
    return {
        "beats": clean_beats,
        "downbeats": clean_downbeats,
        "bars": bars,
        "bpm": round(float(bpm), 3),
        "beat_step": float(beat_step),
        "provider": provider,
    }


def _clean_times(values: Iterable[float], duration: float, limit: int) -> List[float]:
    out: List[float] = []
    seen = set()
    for value in values:
        time = round(float(value), 3)
        if time < 0 or (duration > 0 and time > duration):
            continue
        if time in seen:
            continue
        seen.add(time)
        out.append(time)
        if len(out) >= limit:
            break
    return sorted(out)
