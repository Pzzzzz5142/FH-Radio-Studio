from __future__ import annotations

from typing import Dict, Iterable, List


def normalize_segments(
    segments: Iterable[Dict[str, object]],
    provider: str,
    confidence: float,
) -> List[Dict[str, object]]:
    out: List[Dict[str, object]] = []
    for item in segments:
        start = float(item.get("start", 0.0))
        end = float(item.get("end", start))
        if end <= start:
            continue
        out.append(
            {
                "start": round(start, 3),
                "end": round(end, 3),
                "label": str(item.get("label") or "segment"),
                "confidence": round(float(confidence), 3),
                "provider": provider,
            }
        )
    return out
