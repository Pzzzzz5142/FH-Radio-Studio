from __future__ import annotations

from pathlib import Path
from time import perf_counter
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from ...audio import (
    read_audio_for_analysis,
    waveform_summary,
)
from ...common import TARGET_SAMPLE_RATE, peak_dbfs, rms_dbfs
from ..generation.grid import build_grid, build_grid_from_beats
from ..generation.loop_candidates import build_loop_candidates
from ..generation.point_candidates import build_point_candidates
from ..generation.ranker import (
    sort_point_candidates,
    sort_post_loop_candidates,
    sort_track_loop_candidates,
)
from ..generation.segments import normalize_segments
from ..schema import ProviderStatus, clamp_time, loop_candidate, point_candidate

_TRACK_LOOP_CANDIDATE_LIMIT = 16
_POST_LOOP_CANDIDATE_LIMIT = 64


def check() -> ProviderStatus:
    return ProviderStatus(
        name="baseline_mir",
        status="ok",
        version="numpy-mir-v1",
        device="cpu",
        warnings=[
            "Baseline MIR uses local numpy features. Deep providers are still required for product-quality ranking."
        ],
    )


def analyze(
    source: Path,
    *,
    bins: int,
    bpm: float,
    max_beats: int,
    ffmpeg: Optional[str],
    beat_evidence: Optional[Dict[str, object]] = None,
) -> Dict[str, object]:
    started = perf_counter()
    data, sample_rate, decoder = read_audio_for_analysis(source, ffmpeg=ffmpeg)
    samples = int(data.shape[0])
    duration = samples / sample_rate if sample_rate else 0.0
    waveform = waveform_summary(data, bins)
    mono = _mono(data)
    features = _extract_features(mono, sample_rate)
    estimated_bpm, bpm_confidence = _estimate_bpm(features, fallback_bpm=_coerce_bpm(bpm))
    grid_provider = "baseline_mir"
    if beat_evidence and beat_evidence.get("beats"):
        grid_provider = str(beat_evidence.get("provider") or "beat_provider")
        grid = build_grid_from_beats(
            [float(value) for value in beat_evidence.get("beats", [])],
            [float(value) for value in beat_evidence.get("downbeats", [])],
            duration=duration,
            max_beats=max_beats,
            fallback_bpm=estimated_bpm,
            provider=grid_provider,
        )
        estimated_bpm = float(grid.get("bpm", estimated_bpm))
        bpm_confidence = max(
            bpm_confidence,
            float(beat_evidence.get("confidence", 0.0)),
        )
    else:
        grid = build_grid(duration, estimated_bpm, max_beats)
        grid["provider"] = grid_provider
    beat_step = float(grid["beat_step"])
    segments = _build_segments(duration, features)
    timing = _timing_from_candidates(
        data,
        sample_rate,
        duration,
        features,
        grid,
        beat_step,
    )

    def marker_sec(name: str) -> float:
        return round(float(timing.get(name, 0)) / sample_rate, 3) if sample_rate else 0.0

    markers = {
        "TrackDrop": marker_sec("TrackDrop"),
        "PostDrop": marker_sec("PostDrop"),
        "TrackLoopStart": marker_sec("TrackLoopStart"),
        "TrackLoopEnd": marker_sec("TrackLoopEnd"),
        "PostRaceLoopStart": marker_sec("PostRaceLoopStart"),
        "PostRaceLoopEnd": marker_sec("PostRaceLoopEnd"),
    }
    td_candidates = _trackdrop_point_candidates(
        duration, features, grid, beat_step, markers["TrackDrop"]
    )
    pd_candidates = _postdrop_point_candidates(
        duration, features, grid, beat_step, markers["PostDrop"]
    )
    candidates = {
        "td": td_candidates,
        "pd": pd_candidates,
        "tl": _track_loop_candidates(
            duration,
            mono,
            sample_rate,
            grid,
            beat_step,
            markers["TrackLoopStart"],
            markers["TrackLoopEnd"],
            min_start=_track_loop_min_start_from_td(td_candidates, beat_step),
        ),
        "pl": _post_loop_candidates(
            duration,
            mono,
            sample_rate,
            grid,
            beat_step,
            markers["PostRaceLoopStart"],
            markers["PostRaceLoopEnd"],
            min_start=0.0,
        ),
    }

    status = check()
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return {
        "status": status,
        "duration_sec": duration,
        "sample_rate": sample_rate,
        "channels": int(data.shape[1]) if data.ndim > 1 else 1,
        "samples": samples,
        "decoder": decoder,
        "peak_dbfs": peak_dbfs(data),
        "rms_dbfs": rms_dbfs(data),
        "bpm": estimated_bpm,
        "bpm_confidence": bpm_confidence,
        "waveform": waveform,
        "markers": markers,
        "grid": {
            "beats": grid["beats"],
            "downbeats": grid["downbeats"],
            "bars": grid["bars"],
            "provider": grid_provider,
        },
        "segments": normalize_segments(segments, "baseline_mir", 0.45),
        "candidates": candidates,
        "warnings": (
            [
                "Using local-base MIR evidence. Deep providers are still needed for final-quality candidates."
            ]
            if grid_provider == "baseline_mir"
            else ["Using Beat This beat/downbeat grid with local-base candidate generation."]
        ),
    }


def estimate_timing(
    data: np.ndarray,
    sample_rate: int,
    *,
    bpm: object = 0.0,
    max_beats: int = 800,
    beat_evidence: Optional[Dict[str, object]] = None,
) -> Dict[str, int]:
    samples = int(data.shape[0]) if getattr(data, "ndim", 0) else int(len(data))
    if samples <= 0 or sample_rate <= 0:
        return _fallback_timing(samples, sample_rate)

    duration = samples / sample_rate
    mono = _mono(data)
    features = _extract_features(mono, sample_rate)
    estimated_bpm, _ = _estimate_bpm(features, fallback_bpm=_coerce_bpm(bpm))
    if beat_evidence and beat_evidence.get("beats"):
        grid = build_grid_from_beats(
            [float(value) for value in beat_evidence.get("beats", [])],
            [float(value) for value in beat_evidence.get("downbeats", [])],
            duration=duration,
            max_beats=max_beats,
            fallback_bpm=estimated_bpm,
            provider=str(beat_evidence.get("provider") or "beat_provider"),
        )
        estimated_bpm = float(grid.get("bpm", estimated_bpm))
    else:
        grid = build_grid(duration, estimated_bpm, max_beats)
        grid["provider"] = "baseline_mir"
    return _timing_from_candidates(
        data,
        sample_rate,
        duration,
        features,
        grid,
        float(grid["beat_step"]),
    )


def _coerce_bpm(value: object) -> float:
    try:
        bpm = float(value)
    except (TypeError, ValueError):
        return 0.0
    return bpm if bpm > 0 else 0.0


def _mono(data) -> np.ndarray:
    mono = data.mean(axis=1) if data.ndim > 1 else data
    return np.asarray(mono, dtype=np.float32)


def _extract_features(mono: np.ndarray, sample_rate: int) -> Dict[str, np.ndarray]:
    if sample_rate <= 0 or mono.size == 0:
        return {
            "times": np.zeros(0, dtype=np.float32),
            "rms": np.zeros(0, dtype=np.float32),
            "flux": np.zeros(0, dtype=np.float32),
            "novelty": np.zeros(0, dtype=np.float32),
        }
    n_fft = max(1024, min(4096, int(sample_rate * 0.046)))
    hop = max(256, int(sample_rate * 0.023))
    if mono.size < n_fft:
        padded = np.pad(mono, (0, n_fft - mono.size))
    else:
        padded = mono
    window = np.hanning(n_fft).astype(np.float32)
    starts = np.arange(0, max(1, padded.size - n_fft + 1), hop, dtype=np.int64)
    rms = np.zeros(starts.size, dtype=np.float32)
    flux = np.zeros(starts.size, dtype=np.float32)
    low_ratio = np.zeros(starts.size, dtype=np.float32)
    prev_mag: Optional[np.ndarray] = None
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate)
    low_mask = freqs <= 180.0
    for idx, start in enumerate(starts):
        frame = padded[start : start + n_fft]
        if frame.size < n_fft:
            frame = np.pad(frame, (0, n_fft - frame.size))
        rms[idx] = float(np.sqrt(np.mean(frame * frame)))
        mag = np.abs(np.fft.rfft(frame * window)).astype(np.float32)
        total = float(np.sum(mag) + 1e-9)
        low_ratio[idx] = float(np.sum(mag[low_mask]) / total)
        if prev_mag is None:
            flux[idx] = 0.0
        else:
            diff = mag - prev_mag
            flux[idx] = float(np.sum(diff[diff > 0]) / total)
        prev_mag = mag
    rms_norm = _normalize_curve(rms)
    flux_norm = _normalize_curve(flux)
    rms_delta = np.maximum(0.0, np.diff(rms_norm, prepend=rms_norm[:1] if rms_norm.size else 0))
    novelty = _smooth(_normalize_curve(rms_delta) * 0.45 + flux_norm * 0.55, 5)
    times = (starts + n_fft / 2) / sample_rate
    return {
        "times": times.astype(np.float32),
        "rms": rms_norm.astype(np.float32),
        "raw_rms": rms.astype(np.float32),
        "flux": flux_norm.astype(np.float32),
        "low_ratio": low_ratio.astype(np.float32),
        "novelty": novelty.astype(np.float32),
    }


def _normalize_curve(values: np.ndarray) -> np.ndarray:
    if values.size == 0:
        return values.astype(np.float32)
    lo = float(np.percentile(values, 5))
    hi = float(np.percentile(values, 95))
    if hi <= lo + 1e-9:
        peak = float(np.max(values))
        return (
            (values / (peak + 1e-9)).astype(np.float32)
            if peak > 0
            else np.zeros_like(values, dtype=np.float32)
        )
    return np.clip((values - lo) / (hi - lo), 0.0, 1.0).astype(np.float32)


def _smooth(values: np.ndarray, size: int) -> np.ndarray:
    if values.size == 0 or size <= 1:
        return values.astype(np.float32)
    kernel = np.ones(size, dtype=np.float32) / size
    return np.convolve(values, kernel, mode="same").astype(np.float32)


def _estimate_bpm(features: Dict[str, np.ndarray], fallback_bpm: float) -> Tuple[float, float]:
    novelty = np.asarray(features.get("novelty", []), dtype=np.float32)
    times = np.asarray(features.get("times", []), dtype=np.float32)
    if novelty.size < 8 or times.size < 2:
        return float(fallback_bpm), 0.1
    env = novelty - float(np.mean(novelty))
    frame_rate = 1.0 / max(1e-6, float(np.median(np.diff(times))))
    scores: List[Tuple[float, float]] = []
    for bpm in np.linspace(70.0, 180.0, 221):
        lag = int(round(frame_rate * 60.0 / bpm))
        if lag < 2 or lag >= env.size - 2:
            continue
        score = float(np.dot(env[:-lag], env[lag:]) / max(1, env.size - lag))
        scores.append((score, float(bpm)))
    if not scores:
        return float(fallback_bpm), 0.1
    scores.sort(reverse=True)
    best_score, best_bpm = scores[0]
    second = scores[1][0] if len(scores) > 1 else 0.0
    confidence = max(0.1, min(0.75, (best_score - second + max(best_score, 0.0)) * 2.0))
    return round(best_bpm, 3), round(confidence, 3)


def _build_segments(duration: float, features: Dict[str, np.ndarray]) -> List[Dict[str, object]]:
    if duration <= 0:
        return []
    times = np.asarray(features.get("times", []), dtype=np.float32)
    novelty = np.asarray(features.get("novelty", []), dtype=np.float32)
    rms = np.asarray(features.get("rms", []), dtype=np.float32)
    min_gap = 10.0 if duration > 90 else max(4.0, duration / 8)
    boundaries = [0.0]
    for peak_time in _peak_times(times, novelty, threshold=0.62, min_gap_sec=min_gap):
        if 4.0 < peak_time < duration - 4.0:
            boundaries.append(float(peak_time))
    boundaries.append(duration)
    boundaries = _dedupe_times(sorted(boundaries), min_gap=2.0)
    if len(boundaries) <= 2 and duration > 45:
        boundaries = [
            0.0,
            duration * 0.18,
            duration * 0.40,
            duration * 0.64,
            duration * 0.84,
            duration,
        ]
    segments: List[Dict[str, object]] = []
    for index, (start, end) in enumerate(zip(boundaries, boundaries[1:]), start=1):
        if end <= start:
            continue
        energy = _mean_between(times, rms, start, end)
        if energy >= 0.68:
            label = f"section_{index:02d}_high"
        elif energy <= 0.32:
            label = f"section_{index:02d}_low"
        else:
            label = f"section_{index:02d}_mid"
        segments.append({"start": round(start, 3), "end": round(end, 3), "label": label})
    return segments or [{"start": 0.0, "end": round(duration, 3), "label": "section_01"}]


def _peak_times(
    times: np.ndarray, values: np.ndarray, threshold: float, min_gap_sec: float
) -> List[float]:
    if times.size == 0 or values.size < 3:
        return []
    threshold_value = max(float(np.percentile(values, 75)), threshold)
    peaks: List[Tuple[float, float]] = []
    for idx in range(1, values.size - 1):
        value = float(values[idx])
        if (
            value >= threshold_value
            and value >= float(values[idx - 1])
            and value >= float(values[idx + 1])
        ):
            peaks.append((value, float(times[idx])))
    peaks.sort(reverse=True)
    selected: List[float] = []
    for _, time in peaks:
        if all(abs(time - existing) >= min_gap_sec for existing in selected):
            selected.append(time)
    return sorted(selected)


def _timing_from_candidates(
    data,
    sample_rate: int,
    duration: float,
    features: Dict[str, np.ndarray],
    grid: Dict[str, object],
    beat_step: float,
) -> Dict[str, int]:
    fallback = _fallback_timing(int(data.shape[0]), sample_rate)
    if duration <= 0 or sample_rate <= 0:
        return fallback
    td_candidate = _best_trackdrop_candidate(
        duration, features, grid, fallback["TrackDrop"] / sample_rate
    )
    pd_candidate = _best_postdrop_candidate(
        duration, features, grid, fallback["PostDrop"] / sample_rate
    )
    td = float(td_candidate.get("t", fallback["TrackDrop"] / sample_rate))
    pd = float(pd_candidate.get("t", fallback["PostDrop"] / sample_rate))
    tl_start, tl_end = _best_track_loop_time(
        duration,
        _mono(data),
        sample_rate,
        grid,
        beat_step,
        fallback["TrackLoopStart"] / sample_rate,
        fallback["TrackLoopEnd"] / sample_rate,
        min_start=_track_loop_min_start_from_td([td_candidate], beat_step),
    )
    pl_start, pl_end = _best_post_loop_time(
        duration,
        _mono(data),
        sample_rate,
        grid,
        beat_step,
        fallback["PostRaceLoopStart"] / sample_rate,
        fallback["PostRaceLoopEnd"] / sample_rate,
        min_start=0.0,
    )

    def sec_to_sample(value: float) -> int:
        return int(round(clamp_time(value, duration) * sample_rate))

    return {
        "TrackDrop": sec_to_sample(td),
        "PostDrop": sec_to_sample(pd),
        "TrackLoopStart": sec_to_sample(tl_start),
        "TrackLoopEnd": sec_to_sample(tl_end),
        "PostRaceLoopStart": sec_to_sample(pl_start),
        "PostRaceLoopEnd": sec_to_sample(pl_end),
    }


def _fallback_timing(total_samples: int, sample_rate: int) -> Dict[str, int]:
    if total_samples <= 0:
        return {
            "TrackDrop": -1,
            "PostDrop": -1,
            "TrackLoopStart": -1,
            "TrackLoopEnd": -1,
            "PostRaceLoopStart": -1,
            "PostRaceLoopEnd": -1,
        }
    sr = sample_rate if sample_rate > 0 else TARGET_SAMPLE_RATE
    end = total_samples - 1
    duration = total_samples / sr

    def sec_to_sample(seconds: float) -> int:
        return int(max(0, min(round(seconds * sr), end)))

    if duration <= 8:
        midpoint = max(0, min(end, int(round(total_samples * 0.5))))
        return {
            "TrackDrop": 0,
            "PostDrop": midpoint,
            "TrackLoopStart": 0,
            "TrackLoopEnd": end,
            "PostRaceLoopStart": midpoint,
            "PostRaceLoopEnd": end,
        }

    td = min(max(duration * 0.075, 0.0), max(0.0, duration - 1.0))
    pd = min(max(duration * 0.66, td + min(8.0, duration * 0.1)), max(0.0, duration - 0.5))
    tl_start = td
    tl_end = min(tl_start + 90.0, max(tl_start + 1.0, pd - 2.0), duration)
    if tl_end <= tl_start:
        tl_end = min(duration, tl_start + max(1.0, duration * 0.1))
    pl_start = pd
    pl_end = min(duration, max(pl_start + 1.0, min(pl_start + 60.0, duration)))
    return {
        "TrackDrop": sec_to_sample(td),
        "PostDrop": sec_to_sample(pd),
        "TrackLoopStart": sec_to_sample(tl_start),
        "TrackLoopEnd": sec_to_sample(tl_end),
        "PostRaceLoopStart": sec_to_sample(pl_start),
        "PostRaceLoopEnd": sec_to_sample(pl_end),
    }


def _best_trackdrop_candidate(
    duration: float,
    features: Dict[str, np.ndarray],
    grid: Dict[str, object],
    fallback: float,
) -> Dict[str, object]:
    candidates = _trackdrop_point_candidates(
        duration, features, grid, float(grid["beat_step"]), fallback
    )
    return candidates[0] if candidates else {"t": fallback, "score": 0.0, "evidence": {}}


def _best_postdrop_candidate(
    duration: float,
    features: Dict[str, np.ndarray],
    grid: Dict[str, object],
    fallback: float,
) -> Dict[str, object]:
    candidates = _postdrop_point_candidates(
        duration, features, grid, float(grid["beat_step"]), fallback
    )
    return candidates[0] if candidates else {"t": fallback, "score": 0.0, "evidence": {}}


def _track_loop_min_start_from_td(
    td_candidates: Sequence[Dict[str, object]], beat_step: float
) -> float:
    if not td_candidates:
        return 0.0
    top = td_candidates[0]
    score = float(top.get("score", 0.0))
    evidence = dict(top.get("evidence") or {})
    if evidence.get("track_start_role") == "recognizable_intro_base_kickoff" and score >= 0.55:
        return float(top.get("t", 0.0)) + max(beat_step * 4, 1.0)
    if score >= 0.72:
        return float(top.get("t", 0.0)) + max(beat_step * 4, 1.0)
    return 0.0


def _trackdrop_point_candidates(
    duration: float,
    features: Dict[str, np.ndarray],
    grid: Dict[str, object],
    beat_step: float,
    fallback: float,
) -> List[Dict[str, object]]:
    times = np.asarray(features.get("times", []), dtype=np.float32)
    novelty = np.asarray(features.get("novelty", []), dtype=np.float32)
    rms = np.asarray(features.get("rms", []), dtype=np.float32)
    flux = np.asarray(features.get("flux", []), dtype=np.float32)
    downbeats = [float(value) for value in grid.get("downbeats", [])] or [
        float(value) for value in grid.get("beats", [])
    ]
    search_start = 0.0
    search_end = max(search_start + beat_step * 4, duration * 0.55)
    search_end = min(search_end, max(search_start, duration - beat_step * 8))
    raw_times = _peak_times(times, novelty, threshold=0.45, min_gap_sec=max(beat_step * 2, 2.0))
    raw_times.extend([fallback, search_end])
    raw_times.extend(_early_trackdrop_targets(downbeats, duration))
    raw_times.extend(
        _early_trackdrop_downbeat_targets(
            downbeats,
            duration,
            times,
            rms,
            novelty,
            flux,
            beat_step,
        )
    )
    candidates: List[Dict[str, object]] = []
    seen: set[float] = set()
    for raw_time in raw_times:
        if raw_time < search_start or raw_time > search_end:
            continue
        snapped, delta = _nearest_time(raw_time, downbeats, max_delta=max(0.35, beat_step * 0.5))
        t = clamp_time(snapped, duration)
        key = round(t, 3)
        if key in seen:
            continue
        seen.add(key)
        before = _mean_between(times, rms, t - 4.0, t)
        after = _mean_between(times, rms, t, t + 6.0)
        local_flux = _mean_between(times, flux, t - 1.0, t + 2.0)
        local_novelty = _value_at(times, novelty, t)
        energy_jump = after - before
        align = max(0.0, 1.0 - abs(delta) / max(beat_step, 0.001))
        position_prior = _trackdrop_position_prior(t, duration)
        track_start_prior = _track_start_usability_prior(t, duration)
        score = (
            0.16
            + local_novelty * 0.26
            + max(0.0, energy_jump) * 0.22
            + local_flux * 0.16
            + align * 0.08
            + position_prior * 0.12
            + track_start_prior * 0.22
        )
        if duration > 0:
            late_ratio = t / duration
            if late_ratio > 0.45:
                score -= (late_ratio - 0.45) * 0.9
        candidates.append(
            point_candidate(
                t,
                min(0.82, score),
                _trackdrop_point_why(t, duration, energy_jump, local_novelty),
                {
                    "marker": "TrackDrop",
                    "providers": ["baseline_mir"],
                    "quality": "local_base",
                    "energy_before": round(before, 3),
                    "energy_after": round(after, 3),
                    "energy_jump": round(energy_jump, 3),
                    "novelty": round(local_novelty, 3),
                    "spectral_flux": round(local_flux, 3),
                    "track_start_usability_prior": round(track_start_prior, 3),
                    "track_start_role": (
                        "recognizable_intro_base_kickoff" if track_start_prior >= 0.7 else None
                    ),
                    "nearest_downbeat_delta_ms": int(round(delta * 1000)),
                },
            )
        )
    if not candidates:
        return sort_point_candidates(
            build_point_candidates(
                fallback, duration, beat_step, "TrackDrop", "TrackDrop", "baseline_mir"
            ),
            limit=8,
        )
    return sort_point_candidates(candidates, limit=8)


def _postdrop_point_candidates(
    duration: float,
    features: Dict[str, np.ndarray],
    grid: Dict[str, object],
    beat_step: float,
    fallback: float,
) -> List[Dict[str, object]]:
    times = np.asarray(features.get("times", []), dtype=np.float32)
    novelty = np.asarray(features.get("novelty", []), dtype=np.float32)
    rms = np.asarray(features.get("rms", []), dtype=np.float32)
    flux = np.asarray(features.get("flux", []), dtype=np.float32)
    downbeats = [float(value) for value in grid.get("downbeats", [])] or [
        float(value) for value in grid.get("beats", [])
    ]
    search_start = min(6.0, duration * 0.08)
    search_end = max(search_start + beat_step * 4, duration * 0.96)
    raw_times = _peak_times(times, novelty, threshold=0.45, min_gap_sec=max(beat_step * 2, 2.0))
    raw_times.extend([fallback, search_start, search_end])
    raw_times.extend(
        _postdrop_payoff_targets(
            downbeats,
            duration,
            times,
            rms,
            novelty,
            flux,
            beat_step,
        )
    )
    candidates: List[Dict[str, object]] = []
    seen: set[float] = set()
    for raw_time in raw_times:
        if raw_time < search_start or raw_time > search_end:
            continue
        snapped, delta = _nearest_time(raw_time, downbeats, max_delta=max(0.35, beat_step * 0.5))
        t = clamp_time(snapped, duration)
        key = round(t, 3)
        if key in seen:
            continue
        seen.add(key)
        before = _mean_between(times, rms, t - 4.0, t)
        after = _mean_between(times, rms, t, t + 6.0)
        local_flux = _mean_between(times, flux, t - 1.0, t + 2.0)
        local_novelty = _value_at(times, novelty, t)
        energy_jump = after - before
        align = max(0.0, 1.0 - abs(delta) / max(beat_step, 0.001))
        position_prior = _postdrop_position_prior(t / duration if duration > 0 else 0.0)
        score = (
            0.16
            + local_novelty * 0.26
            + max(0.0, energy_jump) * 0.22
            + local_flux * 0.16
            + align * 0.08
            + position_prior * 0.12
        )
        candidates.append(
            point_candidate(
                t,
                min(0.82, score),
                _postdrop_point_why(t, duration, energy_jump, local_novelty),
                {
                    "marker": "PostDrop",
                    "providers": ["baseline_mir"],
                    "quality": "local_base",
                    "energy_before": round(before, 3),
                    "energy_after": round(after, 3),
                    "energy_jump": round(energy_jump, 3),
                    "novelty": round(local_novelty, 3),
                    "spectral_flux": round(local_flux, 3),
                    "nearest_downbeat_delta_ms": int(round(delta * 1000)),
                },
            )
        )
    if not candidates:
        return sort_point_candidates(
            build_point_candidates(
                fallback, duration, beat_step, "PostDrop", "PostDrop", "baseline_mir"
            ),
            limit=8,
        )
    return sort_point_candidates(candidates, limit=8)


def _trackdrop_point_why(t: float, duration: float, energy_jump: float, novelty: float) -> str:
    if _track_start_usability_prior(t, duration) >= 0.7:
        if energy_jump > 0.12 or novelty > 0.35:
            return "intro/base 中有辨识度的赛车起点"
        return "intro/base 可用起点，local-base 置信度一般"
    base = "前中段结构/能量变化候选"
    if energy_jump > 0.16 and novelty > 0.45:
        return f"{base}，novelty 与能量跃迁都较明显"
    if novelty > 0.45:
        return f"{base}，结构 novelty 较明显"
    if energy_jump > 0.16:
        return f"{base}，边界后能量上升"
    return f"{base}，local-base 置信度一般"


def _postdrop_point_why(t: float, duration: float, energy_jump: float, novelty: float) -> str:
    if duration > 0 and 0.55 <= t / duration <= 0.82:
        base = "赛后高潮/bridge 回归候选"
    else:
        base = "后半段结构/能量回归候选"
    if energy_jump > 0.16 and novelty > 0.45:
        return f"{base}，novelty 与能量跃迁都较明显"
    if novelty > 0.45:
        return f"{base}，结构 novelty 较明显"
    if energy_jump > 0.16:
        return f"{base}，边界后能量上升"
    return f"{base}，local-base 置信度一般"


def _trackdrop_position_prior(t: float, duration: float) -> float:
    if duration <= 0:
        return 0.0
    ratio = t / duration
    target = 0.075
    return max(0.0, 1.0 - abs(ratio - target) / 0.12)


def _postdrop_position_prior(ratio: float) -> float:
    if 0.58 <= ratio <= 0.74:
        return max(0.76, 1.0 - abs(ratio - 0.66) / 0.16)
    if 0.45 <= ratio < 0.58:
        return 0.58 + (ratio - 0.45) / 0.13 * 0.18
    if 0.74 < ratio <= 0.88:
        return 0.74 - (ratio - 0.74) / 0.14 * 0.14
    if 0.25 <= ratio < 0.45:
        return 0.42
    if 0.88 < ratio <= 0.97:
        return 0.40
    return 0.24


def _early_trackdrop_targets(downbeats: Sequence[float], duration: float) -> List[float]:
    if duration <= 0 or not downbeats:
        return []
    latest = min(34.0, max(14.0, duration * 0.12))
    target_times = [
        (duration * 0.015, False),
        (duration * 0.022, False),
        (max(8.0, duration * 0.035), True),
        (max(12.0, duration * 0.075), True),
        (latest, True),
    ]
    selected: List[float] = []
    snap_tolerance = max(0.35, _median_positive_step(downbeats) * 0.25)
    for target, allow_snap in target_times:
        candidates = [value for value in downbeats if 0.0 <= value <= latest]
        if not candidates:
            continue
        nearest = min(candidates, key=lambda value: abs(value - target))
        value = nearest if allow_snap and abs(nearest - target) <= snap_tolerance else target
        if all(abs(value - existing) >= 2.0 for existing in selected):
            selected.append(value)
    return selected


def _early_trackdrop_downbeat_targets(
    downbeats: Sequence[float],
    duration: float,
    times: np.ndarray,
    rms: np.ndarray,
    novelty: np.ndarray,
    flux: np.ndarray,
    beat_step: float,
) -> List[float]:
    if duration <= 0 or not downbeats:
        return []
    latest = min(12.0, max(8.0, duration * 0.05))
    scored: List[Tuple[float, float]] = []
    for value in downbeats:
        if value < 1.0 or value > latest:
            continue
        before = _mean_between(times, rms, value - 4.0, value)
        after = _mean_between(times, rms, value, value + 6.0)
        energy_jump = after - before
        local_novelty = _value_at(times, novelty, value)
        local_flux = _mean_between(times, flux, value - 1.0, value + 2.0)
        if after < 0.08 and energy_jump < 0.08 and local_novelty < 0.25:
            continue
        score = (
            max(0.0, energy_jump) * 0.42 + local_novelty * 0.30 + local_flux * 0.18 + after * 0.10
        )
        scored.append((score, float(value)))
    scored.sort(reverse=True)
    selected: List[float] = []
    min_gap = max(beat_step * 1.5, 0.6)
    for _, value in scored:
        if all(abs(value - existing) >= min_gap for existing in selected):
            selected.append(value)
        if len(selected) >= 4:
            break
    return sorted(selected)


def _median_positive_step(values: Sequence[float]) -> float:
    diffs = [
        values[index] - values[index - 1]
        for index in range(1, len(values))
        if values[index] > values[index - 1]
    ]
    if not diffs:
        return 1.0
    diffs.sort()
    return float(diffs[len(diffs) // 2])


def track_start_opening_readiness(time: float, duration: float) -> float:
    if duration <= 0:
        return 0.0
    if time < 0.0:
        return 0.0
    full_readiness_time = min(3.0, max(1.0, duration * 0.015))
    return max(0.25, min(1.0, 0.25 + 0.75 * (time / full_readiness_time)))


def _postdrop_payoff_targets(
    downbeats: Sequence[float],
    duration: float,
    times: np.ndarray,
    rms: np.ndarray,
    novelty: np.ndarray,
    flux: np.ndarray,
    beat_step: float,
) -> List[float]:
    if duration <= 0 or not downbeats:
        return []
    scored: List[Tuple[float, float]] = []
    for value in downbeats:
        ratio = value / duration
        if ratio < 0.48 or ratio > 0.88:
            continue
        before = _mean_between(times, rms, value - 4.0, value)
        after = _mean_between(times, rms, value, value + 6.0)
        local_flux = _mean_between(times, flux, value - 1.0, value + 2.0)
        local_novelty = _value_at(times, novelty, value)
        position = _postdrop_position_prior(ratio)
        score = (
            max(0.0, after - before) * 0.18
            + after * 0.18
            + local_novelty * 0.24
            + local_flux * 0.18
            + position * 0.22
        )
        scored.append((score, value))
    ratio_targets = [0.62, 0.67, 0.72]
    for target_ratio in ratio_targets:
        target = target_ratio * duration
        nearest = min(downbeats, key=lambda item: abs(item - target))
        if duration * 0.48 <= nearest <= duration * 0.88:
            scored.append((0.72 + _postdrop_position_prior(nearest / duration) * 0.18, nearest))
    scored.sort(reverse=True)
    selected: List[float] = []
    min_gap = max(beat_step * 2.0, 2.0)
    for _, value in scored:
        if all(abs(value - existing) >= min_gap for existing in selected):
            selected.append(float(value))
        if len(selected) >= 8:
            break
    return sorted(selected)


def _track_start_usability_prior(t: float, duration: float) -> float:
    if duration <= 0 or t < 0.0:
        return 0.0
    ratio = t / duration
    if ratio <= 0.09:
        return track_start_opening_readiness(t, duration)
    if ratio <= 0.16:
        return max(0.35, 1.0 - (ratio - 0.09) / 0.07 * 0.65)
    if ratio <= 0.25:
        return max(0.0, 0.35 - (ratio - 0.16) / 0.09 * 0.35)
    return 0.0


def _best_track_loop_time(
    duration: float,
    mono: np.ndarray,
    sample_rate: int,
    grid: Dict[str, object],
    beat_step: float,
    fallback_start: float,
    fallback_end: float,
    min_start: float = 0.0,
) -> Tuple[float, float]:
    candidates = _track_loop_candidates(
        duration,
        mono,
        sample_rate,
        grid,
        beat_step,
        fallback_start,
        fallback_end,
        min_start=min_start,
    )
    if not candidates:
        return fallback_start, fallback_end
    top = candidates[0]
    return float(top["start"]), float(top["end"])


def _best_post_loop_time(
    duration: float,
    mono: np.ndarray,
    sample_rate: int,
    grid: Dict[str, object],
    beat_step: float,
    fallback_start: float,
    fallback_end: float,
    min_start: float = 0.0,
) -> Tuple[float, float]:
    candidates = _post_loop_candidates(
        duration,
        mono,
        sample_rate,
        grid,
        beat_step,
        fallback_start,
        fallback_end,
        min_start=min_start,
    )
    if not candidates:
        return fallback_start, fallback_end
    top = candidates[0]
    return float(top["start"]), float(top["end"])


def _track_loop_candidates(
    duration: float,
    mono: np.ndarray,
    sample_rate: int,
    grid: Dict[str, object],
    beat_step: float,
    fallback_start: float,
    fallback_end: float,
    min_start: float = 0.0,
) -> List[Dict[str, object]]:
    bars = [
        float(item["start"])
        for item in grid.get("bars", [])
        if isinstance(item, dict) and "start" in item
    ]
    if len(bars) < 3:
        return sort_track_loop_candidates(
            build_loop_candidates(
                max(fallback_start, min_start),
                fallback_end,
                duration,
                beat_step,
                "TrackLoop",
                "baseline_mir",
            )
        )
    bar_step = max(beat_step * 4, 0.5)
    lengths = [8, 16, 24, 32, 48, 64]
    candidates: List[Dict[str, object]] = []
    for start in bars:
        if start < min_start or start > duration * 0.92:
            continue
        for length in lengths:
            loop_len = length * bar_step
            end = start + loop_len
            if end > duration - 0.25:
                continue
            sim = _window_similarity(
                mono, sample_rate, end - min(2.0, bar_step), start, min(2.0, bar_step)
            )
            rms_delta_db = _rms_delta_db(mono, sample_rate, end - 1.0, start, 1.0)
            smooth = max(0.0, 1.0 - abs(rms_delta_db) / 8.0)
            length_prior = min(1.0, length / 32.0)
            score = 0.10 + sim * 0.40 + smooth * 0.22 + length_prior * 0.22
            if start < min_start + 0.1:
                score -= 0.08
            candidates.append(
                loop_candidate(
                    start,
                    end,
                    min(0.84, score),
                    length,
                    "TrackLoop · local-base seam similarity",
                    {
                        "providers": ["baseline_mir"],
                        "quality": "local_base",
                        "end_to_start_preview": True,
                        "seam_similarity": round(sim, 3),
                        "rms_delta_db": round(rms_delta_db, 3),
                        "length_prior": round(length_prior, 3),
                        "loop_role": "track_main_loop",
                        "loop_duration_sec": round(end - start, 3),
                        "min_start_sec": round(min_start, 3),
                        "vocal_cut_risk": None,
                    },
                )
            )
    if not candidates:
        return sort_track_loop_candidates(
            build_loop_candidates(
                max(fallback_start, min_start),
                fallback_end,
                duration,
                beat_step,
                "TrackLoop",
                "baseline_mir",
            )
        )
    return sort_track_loop_candidates(candidates, limit=_TRACK_LOOP_CANDIDATE_LIMIT)


def _post_loop_candidates(
    duration: float,
    mono: np.ndarray,
    sample_rate: int,
    grid: Dict[str, object],
    beat_step: float,
    fallback_start: float,
    fallback_end: float,
    min_start: float = 0.0,
) -> List[Dict[str, object]]:
    bars = [
        float(item["start"])
        for item in grid.get("bars", [])
        if isinstance(item, dict) and "start" in item
    ]
    if len(bars) < 3:
        return sort_post_loop_candidates(
            build_loop_candidates(
                max(fallback_start, min_start),
                fallback_end,
                duration,
                beat_step,
                "PostLoop",
                "baseline_mir",
            ),
            limit=_POST_LOOP_CANDIDATE_LIMIT,
        )
    bar_step = max(beat_step * 4, 0.5)
    lengths = [8, 12, 16, 24, 32]
    candidates: List[Dict[str, object]] = []
    for start in bars:
        if start < min_start or start > duration * 0.92:
            continue
        for length in lengths:
            loop_len = length * bar_step
            end = start + loop_len
            if end > duration - 0.25:
                continue
            sim = _window_similarity(
                mono, sample_rate, end - min(2.0, bar_step), start, min(2.0, bar_step)
            )
            rms_delta_db = _rms_delta_db(mono, sample_rate, end - 1.0, start, 1.0)
            smooth = max(0.0, 1.0 - abs(rms_delta_db) / 8.0)
            length_prior = _post_loop_length_prior(length)
            score = 0.12 + sim * 0.42 + smooth * 0.24 + length_prior * 0.16
            if start < min_start + 0.1:
                score -= 0.08
            candidates.append(
                loop_candidate(
                    start,
                    end,
                    min(0.84, score),
                    length,
                    "PostLoop · local-base seam similarity",
                    {
                        "providers": ["baseline_mir"],
                        "quality": "local_base",
                        "end_to_start_preview": True,
                        "seam_similarity": round(sim, 3),
                        "rms_delta_db": round(rms_delta_db, 3),
                        "length_prior": round(length_prior, 3),
                        "loop_role": "post_chorus_loop",
                        "loop_duration_sec": round(end - start, 3),
                        "min_start_sec": round(min_start, 3),
                        "vocal_cut_risk": None,
                    },
                )
            )
    if not candidates:
        return sort_post_loop_candidates(
            build_loop_candidates(
                max(fallback_start, min_start),
                fallback_end,
                duration,
                beat_step,
                "PostLoop",
                "baseline_mir",
            ),
            limit=_POST_LOOP_CANDIDATE_LIMIT,
        )
    return sort_post_loop_candidates(candidates, limit=_POST_LOOP_CANDIDATE_LIMIT)


def _post_loop_length_prior(bars: int) -> float:
    if bars <= 0:
        return 0.0
    if bars == 8:
        return 1.0
    if bars in {4, 12}:
        return 0.82
    if bars == 16:
        return 0.62
    return max(0.0, 0.45 - abs(bars - 8) / 24.0)


def _window_similarity(
    mono: np.ndarray, sample_rate: int, a_start: float, b_start: float, duration: float
) -> float:
    a = _slice_seconds(mono, sample_rate, a_start, duration)
    b = _slice_seconds(mono, sample_rate, b_start, duration)
    if a.size == 0 or b.size == 0:
        return 0.0
    length = min(a.size, b.size)
    a = a[:length] - float(np.mean(a[:length]))
    b = b[:length] - float(np.mean(b[:length]))
    denom = float(np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)
    corr = float(np.dot(a, b) / denom)
    return max(0.0, min(1.0, (corr + 1.0) / 2.0))


def _rms_delta_db(
    mono: np.ndarray, sample_rate: int, a_start: float, b_start: float, duration: float
) -> float:
    a = _slice_seconds(mono, sample_rate, a_start, duration)
    b = _slice_seconds(mono, sample_rate, b_start, duration)
    rms_a = float(np.sqrt(np.mean(a * a)) + 1e-9) if a.size else 1e-9
    rms_b = float(np.sqrt(np.mean(b * b)) + 1e-9) if b.size else 1e-9
    return float(20.0 * np.log10(rms_a / rms_b))


def _slice_seconds(mono: np.ndarray, sample_rate: int, start: float, duration: float) -> np.ndarray:
    if sample_rate <= 0 or duration <= 0:
        return np.zeros(0, dtype=np.float32)
    start_index = max(0, int(round(start * sample_rate)))
    end_index = min(mono.size, int(round((start + duration) * sample_rate)))
    if end_index <= start_index:
        return np.zeros(0, dtype=np.float32)
    return mono[start_index:end_index]


def _nearest_time(
    value: float,
    candidates: Sequence[float],
    *,
    max_delta: Optional[float] = None,
) -> Tuple[float, float]:
    if not candidates:
        return value, 0.0
    nearest = min(candidates, key=lambda item: abs(item - value))
    delta = nearest - value
    if max_delta is not None and abs(delta) > max_delta:
        return value, delta
    return nearest, delta


def _mean_between(times: np.ndarray, values: np.ndarray, start: float, end: float) -> float:
    if times.size == 0 or values.size == 0 or end <= start:
        return 0.0
    mask = (times >= start) & (times < end)
    if not np.any(mask):
        return _value_at(times, values, (start + end) / 2.0)
    return float(np.mean(values[mask]))


def _value_at(times: np.ndarray, values: np.ndarray, time: float) -> float:
    if times.size == 0 or values.size == 0:
        return 0.0
    index = int(np.argmin(np.abs(times - time)))
    return float(values[index])


def _dedupe_times(times: Sequence[float], min_gap: float) -> List[float]:
    out: List[float] = []
    for value in times:
        if not out or abs(value - out[-1]) >= min_gap:
            out.append(float(value))
    return out
