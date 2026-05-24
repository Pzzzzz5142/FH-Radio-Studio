from __future__ import annotations

import contextlib
import copy
import io
import os
from pathlib import Path
from time import perf_counter
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np

from ...audio import read_audio_for_analysis
from ..generation.ranker import (
    sort_point_candidates,
    sort_post_loop_candidates,
    sort_track_loop_candidates,
)
from ..schema import ProviderStatus
from .runtime import cache_has_any, executable_path, module_exists, package_version, torch_device

DEMUCS_MODEL_NAME = "htdemucs"
_WINDOW_SECONDS = 6.0
_HALF_ANALYSIS_SECONDS = 1.5
_MAX_POINT_ITEMS_PER_GROUP = 8
_MAX_LOOP_ITEMS_PER_GROUP = 12
_TRACK_LOOP_CANDIDATE_LIMIT = 16


def check(model_dir: Path, enabled: bool) -> ProviderStatus:
    if not enabled:
        return ProviderStatus(name="demucs", status="disabled")
    runtime_ready = module_exists("demucs") or executable_path("demucs") is not None
    version = package_version("demucs") or "unknown"
    cache_ready = cache_has_any(
        model_dir / "demucs",
        ("*.th", "*.pt", "*.pth", "*.safetensors", "**/*.th", "**/*.pt", "**/*.pth"),
    )
    if runtime_ready:
        warnings = []
        if not cache_ready:
            warnings.append(
                f"Demucs runtime is installed, but no model/cache marker was found under {model_dir / 'demucs'}. "
                "Warm the model during install before relying on offline stem evidence."
            )
        return ProviderStatus(
            name="demucs",
            status="ready" if cache_ready else "partial",
            version=f"{DEMUCS_MODEL_NAME}; demucs {version}",
            device=torch_device(),
            warnings=warnings,
        )
    return ProviderStatus(
        name="demucs",
        status="missing",
        version="demucs package not found",
        warnings=[
            f"Demucs runtime/model is not installed under {model_dir / 'demucs'}; "
            "stem-aware drop and vocal-safe seam evidence is unavailable."
        ],
    )


def warmup(model_dir: Path) -> ProviderStatus:
    started = perf_counter()
    status = check(model_dir, True)
    if not module_exists("demucs") or not module_exists("torch"):
        status.status = "missing"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [
            "Demucs Warmup requires uv-installed demucs and torch. Sync `ai-demucs` with a torch extra first."
        ]
        return status
    try:
        _load_model(model_dir, device="cpu")
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [f"Demucs Warmup failed: {type(exc).__name__}: {exc}"]
        return status
    status = check(model_dir, True)
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return status


def score_candidates(
    source: Path,
    candidates: Dict[str, List[Dict[str, object]]],
    *,
    model_dir: Path,
    ffmpeg: Optional[str],
) -> Dict[str, object]:
    started = perf_counter()
    status = check(model_dir, True)
    if status.status != "ready":
        status.runtime_ms = int((perf_counter() - started) * 1000)
        return {
            "status": status,
            "candidates": candidates,
            "warnings": list(status.warnings),
        }
    try:
        data, sample_rate, _ = read_audio_for_analysis(source, ffmpeg=ffmpeg)
        audio = _stereo(data)
        duration = audio.shape[1] / sample_rate if sample_rate else 0.0
        model, torch = _load_model(model_dir, device=torch_device())
        model_rate = int(getattr(model, "samplerate", 44100))
        model_device = "cuda" if torch_device() == "cuda" and torch.cuda.is_available() else "cpu"
        updated = _score_groups(
            candidates,
            audio,
            sample_rate,
            duration,
            model,
            model_rate,
            model_device,
            torch,
        )
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [
            f"Demucs stem scoring failed; non-stem evidence is being used. {type(exc).__name__}: {exc}"
        ]
        return {"status": status, "candidates": candidates, "warnings": list(status.warnings)}
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return {
        "status": status,
        "candidates": updated,
        "runtime": {
            "requested_device": torch_device(),
            "model_device": model_device,
        },
        "warnings": [],
    }


def _score_groups(
    candidates: Dict[str, List[Dict[str, object]]],
    audio: np.ndarray,
    sample_rate: int,
    duration: float,
    model,
    model_rate: int,
    model_device: str,
    torch,
) -> Dict[str, List[Dict[str, object]]]:
    updated = copy.deepcopy(candidates)
    point_windows: Dict[float, Dict[str, object]] = {}
    loop_windows: Dict[Tuple[float, float], Dict[str, object]] = {}

    for group in ("td", "pd"):
        for item in updated.get(group, [])[:_MAX_POINT_ITEMS_PER_GROUP]:
            time = round(float(item.get("t", 0.0)), 3)
            point_windows.setdefault(
                time,
                _separate_window(
                    audio,
                    sample_rate,
                    time - _WINDOW_SECONDS / 2.0,
                    _WINDOW_SECONDS,
                    model,
                    model_rate,
                    model_device,
                    torch,
                ),
            )
    for group in ("tl", "pl"):
        for item in updated.get(group, [])[:_MAX_LOOP_ITEMS_PER_GROUP]:
            start = round(float(item.get("start", 0.0)), 3)
            end = round(float(item.get("end", start)), 3)
            loop_windows.setdefault(
                (start, end),
                {
                    "start": _separate_window(
                        audio,
                        sample_rate,
                        start,
                        _HALF_ANALYSIS_SECONDS * 2.0,
                        model,
                        model_rate,
                        model_device,
                        torch,
                    ),
                    "end": _separate_window(
                        audio,
                        sample_rate,
                        end - _HALF_ANALYSIS_SECONDS * 2.0,
                        _HALF_ANALYSIS_SECONDS * 2.0,
                        model,
                        model_rate,
                        model_device,
                        torch,
                    ),
                },
            )

    for group in ("td", "pd"):
        rescored: List[Dict[str, object]] = []
        for item in updated.get(group, []):
            time = round(float(item.get("t", 0.0)), 3)
            evidence_blob = point_windows.get(time)
            if evidence_blob is None:
                rescored.append(item)
                continue
            metrics = _point_metrics(evidence_blob)
            bonus = _long_intro_stem_confirmation_bonus(item.get("evidence"), metrics)
            if bonus:
                metrics["long_intro_stem_confirmation_bonus"] = bonus
                metrics["long_intro_stem_confirmation_policy"] = (
                    "SongFormer long intro downbeat confirmed by stem jump"
                )
            item["score"] = round(
                min(0.96, _combine_point_score(float(item.get("score", 0.0)), metrics) + bonus),
                3,
            )
            item["why"] = f"{item.get('why', 'point candidate')} · Demucs stem evidence"
            item["evidence"] = _merge_evidence(item.get("evidence"), metrics)
            rescored.append(item)
        updated[group] = sort_point_candidates(rescored, limit=8)

    for group in ("tl", "pl"):
        rescored = []
        for item in updated.get(group, []):
            key = (round(float(item.get("start", 0.0)), 3), round(float(item.get("end", 0.0)), 3))
            evidence_blob = loop_windows.get(key)
            if evidence_blob is None:
                rescored.append(item)
                continue
            metrics = _loop_metrics(evidence_blob["end"], evidence_blob["start"])
            item["score"] = _combine_loop_score(float(item.get("score", 0.0)), metrics)
            item["why"] = f"{item.get('why', 'loop candidate')} · Demucs vocal-safe seam"
            item["evidence"] = _merge_evidence(item.get("evidence"), metrics)
            rescored.append(item)
        updated[group] = (
            sort_post_loop_candidates(rescored, limit=8)
            if group == "pl"
            else sort_track_loop_candidates(rescored, limit=_TRACK_LOOP_CANDIDATE_LIMIT)
        )

    return updated


def _load_model(model_dir: Path, *, device: str):
    import torch
    from demucs.pretrained import get_model

    root = model_dir / "demucs" / "torch_home"
    root.mkdir(parents=True, exist_ok=True)
    previous = os.environ.get("TORCH_HOME")
    os.environ["TORCH_HOME"] = str(root)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            model = get_model(DEMUCS_MODEL_NAME)
    finally:
        if previous is None:
            os.environ.pop("TORCH_HOME", None)
        else:
            os.environ["TORCH_HOME"] = previous
    target = "cuda" if device == "cuda" and torch.cuda.is_available() else "cpu"
    return model.to(target).eval(), torch


def _separate_window(
    audio: np.ndarray,
    sample_rate: int,
    start: float,
    duration: float,
    model,
    model_rate: int,
    model_device: str,
    torch,
) -> Dict[str, object]:
    import torchaudio.functional as F
    from demucs.apply import apply_model

    start_index = int(round(start * sample_rate))
    length = max(1, int(round(duration * sample_rate)))
    clip = np.zeros((2, length), dtype=np.float32)
    source_start = max(0, start_index)
    source_end = min(audio.shape[1], start_index + length)
    if source_end > source_start:
        target_start = max(0, -start_index)
        clip[:, target_start : target_start + (source_end - source_start)] = audio[
            :, source_start:source_end
        ]
    tensor = torch.from_numpy(clip).unsqueeze(0)
    if sample_rate != model_rate:
        tensor = F.resample(tensor, sample_rate, model_rate)
    tensor = tensor.to(model_device)
    with torch.inference_mode():
        stems = apply_model(
            model,
            tensor,
            shifts=0,
            split=False,
            progress=False,
            device=model_device,
        )
    stems_np = stems.detach().cpu().numpy()[0].astype(np.float32)
    return {
        "stems": stems_np,
        "sources": list(getattr(model, "sources", ["drums", "bass", "other", "vocals"])),
        "sample_rate": model_rate,
    }


def _point_metrics(blob: Dict[str, object]) -> Dict[str, object]:
    stems = blob["stems"]  # type: ignore[assignment]
    sample_rate = int(blob["sample_rate"])
    sources = list(blob["sources"])  # type: ignore[arg-type]
    center = stems.shape[-1] // 2
    half = max(1, int(round(_HALF_ANALYSIS_SECONDS * sample_rate)))
    before = stems[:, :, max(0, center - half) : center]
    after = stems[:, :, center : min(stems.shape[-1], center + half)]
    drums_jump = _stem_jump_db(before, after, sources, "drums")
    bass_jump = _stem_jump_db(before, after, sources, "bass")
    vocal_ratio = _stem_ratio(
        stems[:, :, max(0, center - half // 2) : min(stems.shape[-1], center + half // 2)],
        sources,
        "vocals",
    )
    return {
        "demucs_model": DEMUCS_MODEL_NAME,
        "demucs_drums_jump_db": round(drums_jump, 3),
        "demucs_bass_jump_db": round(bass_jump, 3),
        "demucs_vocal_boundary_ratio": round(vocal_ratio, 3),
        "demucs_vocal_cut_risk": round(min(1.0, vocal_ratio * 1.35), 3),
    }


def _loop_metrics(end_blob: Dict[str, object], start_blob: Dict[str, object]) -> Dict[str, object]:
    end_stems = end_blob["stems"]  # type: ignore[assignment]
    start_stems = start_blob["stems"]  # type: ignore[assignment]
    sources = list(end_blob["sources"])  # type: ignore[arg-type]
    end_tail = end_stems[:, :, end_stems.shape[-1] // 2 :]
    start_head = start_stems[:, :, : start_stems.shape[-1] // 2]
    drums_sim = _stem_energy_similarity(end_tail, start_head, sources, "drums")
    bass_sim = _stem_energy_similarity(end_tail, start_head, sources, "bass")
    vocal_ratio = max(
        _stem_ratio(end_tail, sources, "vocals"),
        _stem_ratio(start_head, sources, "vocals"),
    )
    return {
        "demucs_model": DEMUCS_MODEL_NAME,
        "demucs_drums_seam_similarity": round(drums_sim, 3),
        "demucs_bass_seam_similarity": round(bass_sim, 3),
        "demucs_vocal_seam_ratio": round(vocal_ratio, 3),
        "demucs_vocal_cut_risk": round(min(1.0, vocal_ratio * 1.35), 3),
    }


def _stem_jump_db(before: np.ndarray, after: np.ndarray, sources: List[str], stem: str) -> float:
    idx = _source_index(sources, stem)
    if idx is None:
        return 0.0
    return _db(_rms(after[idx])) - _db(_rms(before[idx]))


def _stem_ratio(stems: np.ndarray, sources: List[str], stem: str) -> float:
    idx = _source_index(sources, stem)
    if idx is None:
        return 0.0
    target = _rms(stems[idx])
    total = float(sum(_rms(stems[index]) for index in range(stems.shape[0])) + 1e-9)
    return max(0.0, min(1.0, target / total))


def _stem_energy_similarity(a: np.ndarray, b: np.ndarray, sources: List[str], stem: str) -> float:
    idx = _source_index(sources, stem)
    if idx is None:
        return 0.0
    a_db = _db(_rms(a[idx]))
    b_db = _db(_rms(b[idx]))
    return max(0.0, min(1.0, 1.0 - abs(a_db - b_db) / 18.0))


def _source_index(sources: List[str], stem: str) -> Optional[int]:
    try:
        return sources.index(stem)
    except ValueError:
        return None


def _rms(values: np.ndarray) -> float:
    if values.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(values.astype(np.float32))) + 1e-12))


def _db(value: float) -> float:
    return 20.0 * float(np.log10(max(value, 1e-8)))


def _combine_point_score(base: float, metrics: Dict[str, object]) -> float:
    drums = max(0.0, min(1.0, float(metrics["demucs_drums_jump_db"]) / 12.0))
    bass = max(0.0, min(1.0, float(metrics["demucs_bass_jump_db"]) / 12.0))
    vocal_risk = max(0.0, min(1.0, float(metrics["demucs_vocal_cut_risk"])))
    score = base * 0.72 + drums * 0.12 + bass * 0.12 + (1.0 - vocal_risk) * 0.04 - vocal_risk * 0.05
    return round(max(0.0, min(0.96, score)), 3)


def _long_intro_stem_confirmation_bonus(existing: object, metrics: Dict[str, object]) -> float:
    evidence = dict(existing or {})
    if evidence.get("songformer_point_role") != "long_intro_downbeat":
        return 0.0
    drums = max(0.0, min(1.0, float(metrics["demucs_drums_jump_db"]) / 12.0))
    bass = max(0.0, min(1.0, float(metrics["demucs_bass_jump_db"]) / 12.0))
    confirmation = max(drums, bass)
    if confirmation < 0.35:
        return 0.0
    return round(0.08 * confirmation, 3)


def _combine_loop_score(base: float, metrics: Dict[str, object]) -> float:
    drums = float(metrics["demucs_drums_seam_similarity"])
    bass = float(metrics["demucs_bass_seam_similarity"])
    vocal_risk = max(0.0, min(1.0, float(metrics["demucs_vocal_cut_risk"])))
    score = base * 0.72 + drums * 0.09 + bass * 0.11 + (1.0 - vocal_risk) * 0.08 - vocal_risk * 0.06
    return round(max(0.0, min(0.96, score)), 3)


def _merge_evidence(existing: object, metrics: Dict[str, object]) -> Dict[str, object]:
    evidence = dict(existing or {})
    providers = list(evidence.get("providers") or [])
    if "demucs" not in providers:
        providers.append("demucs")
    evidence["providers"] = providers
    evidence.update(metrics)
    return evidence


def _stereo(data: np.ndarray) -> np.ndarray:
    array = np.asarray(data, dtype=np.float32)
    if array.ndim == 1:
        return np.stack([array, array], axis=0)
    if array.shape[1] == 1:
        mono = array[:, 0]
        return np.stack([mono, mono], axis=0)
    return array[:, :2].T.copy()
