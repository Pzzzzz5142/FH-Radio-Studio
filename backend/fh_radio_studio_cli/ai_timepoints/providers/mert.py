from __future__ import annotations

import contextlib
import copy
import io
from pathlib import Path
from time import perf_counter
from typing import Dict, List, Optional, Tuple

import numpy as np

from ...audio import read_audio_for_analysis
from ..generation.ranker import (
    sort_point_candidates,
    sort_post_loop_candidates,
    sort_track_loop_candidates,
)
from ..schema import ProviderStatus
from .hf_download import download_hf_snapshot, remove_invalid_repo_dir
from .runtime import cache_has_any, module_exists, package_version, torch_device

MERT_MODEL_ID = "m-a-p/MERT-v1-95M"
_CACHE_SUBDIR = "mert"
_REPO_SUBDIR = "repo"
_ALLOW_PATTERNS = (
    "*.json",
    "*.py",
    "*.safetensors",
    "*.bin",
    "*.pt",
    "*.txt",
    "*.model",
)
_WINDOW_SECONDS = 2.0
_BATCH_SIZE = 8
_TRACK_LOOP_CANDIDATE_LIMIT = 16


def check(model_dir: Path, enabled: bool) -> ProviderStatus:
    if not enabled:
        return ProviderStatus(name="mert", status="disabled")
    deps_ready = module_exists("torch") and module_exists("transformers")
    version = package_version("transformers")
    cache_ready = _ready_repo_dir(model_dir) is not None or _legacy_cache_ready(model_dir)
    if deps_ready and cache_ready:
        return ProviderStatus(
            name="mert",
            status="ready",
            version=f"{MERT_MODEL_ID}; transformers {version or 'unknown'}",
            device=torch_device(),
        )
    if deps_ready or cache_ready:
        missing = []
        if not deps_ready:
            missing.append("torch/transformers")
        if not cache_ready:
            missing.append(f"local {MERT_MODEL_ID} cache")
        return ProviderStatus(
            name="mert",
            status="partial",
            version=f"{MERT_MODEL_ID}; transformers {version or 'unknown'}",
            device=torch_device(),
            warnings=[
                "MERT is partially installed; missing "
                + ", ".join(missing)
                + ". Loop similarity is using fallback evidence only."
            ],
        )
    return ProviderStatus(
        name="mert",
        status="missing",
        version=f"{MERT_MODEL_ID} not cached",
        warnings=[
            f"MERT dependencies/cache are not installed under {_repo_dir(model_dir)}; "
            "loop similarity is using fallback evidence only."
        ],
    )


def warmup(model_dir: Path) -> ProviderStatus:
    started = perf_counter()
    status = check(model_dir, True)
    if not module_exists("torch") or not module_exists("transformers"):
        status.status = "missing"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [
            "MERT Warmup requires uv-installed torch and transformers. "
            "Sync `ai-mert` with either the `torch-cu128` or `torch-cpu` extra first."
        ]
        return status
    try:
        repo_dir = _ensure_repo(model_dir)
        _load_model_and_feature_extractor(repo_dir, local_only=True)
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [f"MERT Warmup failed: {type(exc).__name__}: {exc}"]
        return status
    status = check(model_dir, True)
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return status


def score_loop_candidates(
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
        mono = data.mean(axis=1) if data.ndim > 1 else data
        repo_dir = _ready_repo_dir(model_dir)
        if repo_dir is not None:
            feature_extractor, model, torch = _load_model_and_feature_extractor(
                repo_dir, local_only=True
            )
        else:
            feature_extractor, model, torch = _load_legacy_model_and_feature_extractor(
                model_dir, local_only=True
            )
        target_rate = int(getattr(feature_extractor, "sampling_rate", 24000))
        resampled = _resample_mono(mono.astype(np.float32), sample_rate, target_rate, torch)
        updated = _score_candidate_groups(
            candidates,
            resampled,
            target_rate,
            feature_extractor,
            model,
            torch,
        )
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [
            f"MERT loop scoring failed; baseline loop evidence is being used. {type(exc).__name__}: {exc}"
        ]
        return {
            "status": status,
            "candidates": candidates,
            "warnings": list(status.warnings),
        }
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return {
        "status": status,
        "candidates": updated,
        "runtime": {
            "requested_device": torch_device(),
        },
        "warnings": [],
    }


def _load_model_and_feature_extractor(
    repo_dir: Path, *, local_only: bool
) -> Tuple[object, object, object]:
    import torch
    from transformers import AutoFeatureExtractor, AutoModel

    load_target = str(repo_dir)
    kwargs = {
        "trust_remote_code": True,
        "local_files_only": local_only,
    }
    with contextlib.redirect_stdout(io.StringIO()):
        feature_extractor = AutoFeatureExtractor.from_pretrained(load_target, **kwargs)
        model = AutoModel.from_pretrained(load_target, dtype="auto", **kwargs)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device).eval()
    return feature_extractor, model, torch


def _load_legacy_model_and_feature_extractor(
    model_dir: Path, *, local_only: bool
) -> Tuple[object, object, object]:
    import torch
    from transformers import AutoFeatureExtractor, AutoModel

    cache_dir = _legacy_hf_cache_dir(model_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    kwargs = {
        "trust_remote_code": True,
        "cache_dir": str(cache_dir),
        "local_files_only": local_only,
    }
    with contextlib.redirect_stdout(io.StringIO()):
        feature_extractor = AutoFeatureExtractor.from_pretrained(MERT_MODEL_ID, **kwargs)
        model = AutoModel.from_pretrained(MERT_MODEL_ID, dtype="auto", **kwargs)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = model.to(device).eval()
    return feature_extractor, model, torch


def _download_repo(model_dir: Path) -> Path:
    return download_hf_snapshot(
        repo_id=MERT_MODEL_ID,
        repo_type="model",
        local_dir=_repo_dir(model_dir),
        allow_patterns=_ALLOW_PATTERNS,
    )


def _ensure_repo(model_dir: Path) -> Path:
    ready = _ready_repo_dir(model_dir)
    if ready is not None:
        return ready
    repo_dir = _repo_dir(model_dir)
    if repo_dir.exists():
        remove_invalid_repo_dir(repo_dir, provider_dir=_provider_dir(model_dir))
    return _download_repo(model_dir)


def _repo_dir(model_dir: Path) -> Path:
    return _provider_dir(model_dir) / _REPO_SUBDIR


def _provider_dir(model_dir: Path) -> Path:
    return model_dir / _CACHE_SUBDIR


def _repo_candidates(model_dir: Path) -> Tuple[Path, ...]:
    return (_repo_dir(model_dir), _provider_dir(model_dir))


def _ready_repo_dir(model_dir: Path) -> Optional[Path]:
    for repo_dir in _repo_candidates(model_dir):
        if _cache_ready(repo_dir):
            return repo_dir
    return None


def _cache_ready(repo_dir: Path) -> bool:
    return (
        (repo_dir / "config.json").is_file()
        and (repo_dir / "preprocessor_config.json").is_file()
        and cache_has_any(repo_dir, ("*.safetensors", "*.bin", "*.pt"))
    )


def _legacy_hf_cache_dir(model_dir: Path) -> Path:
    return model_dir / "huggingface" / "hub"


def _legacy_cache_ready(model_dir: Path) -> bool:
    return cache_has_any(
        model_dir,
        (
            "huggingface/hub/models--m-a-p--MERT-v1-95M/**/config.json",
            "huggingface/hub/models--m-a-p--MERT-v1-95M/**/preprocessor_config.json",
        ),
    ) and cache_has_any(
        model_dir,
        (
            "huggingface/hub/models--m-a-p--MERT-v1-95M/**/*.safetensors",
            "huggingface/hub/models--m-a-p--MERT-v1-95M/**/*.bin",
            "huggingface/hub/models--m-a-p--MERT-v1-95M/**/*.pt",
        ),
    )


def _resample_mono(mono: np.ndarray, source_rate: int, target_rate: int, torch) -> np.ndarray:
    if source_rate == target_rate:
        return mono.astype(np.float32)
    import torchaudio.functional as F

    tensor = torch.from_numpy(mono.astype(np.float32))
    resampled = F.resample(tensor, source_rate, target_rate)
    return resampled.cpu().numpy().astype(np.float32)


def _score_candidate_groups(
    candidates: Dict[str, List[Dict[str, object]]],
    mono: np.ndarray,
    sample_rate: int,
    feature_extractor,
    model,
    torch,
) -> Dict[str, List[Dict[str, object]]]:
    updated = copy.deepcopy(candidates)
    for group in ("td", "pd"):
        items = updated.get(group, [])
        if not items:
            continue
        windows = []
        for item in items:
            time = float(item.get("t", 0.0))
            windows.append(_window(mono, sample_rate, time - _WINDOW_SECONDS, _WINDOW_SECONDS))
            windows.append(_window(mono, sample_rate, time, _WINDOW_SECONDS))
        embeddings = _embed_windows(windows, feature_extractor, model, torch)
        rescored = []
        for index, item in enumerate(items):
            before = embeddings[index * 2]
            after = embeddings[index * 2 + 1]
            novelty = 1.0 - _cosine(before, after)
            item["score"] = _combined_point_score(float(item.get("score", 0.0)), novelty)
            item["why"] = f"{item.get('why', 'point candidate')} · MERT transition novelty"
            evidence = dict(item.get("evidence") or {})
            providers = list(evidence.get("providers") or [])
            if "mert" not in providers:
                providers.append("mert")
            evidence["providers"] = providers
            evidence["mert_novelty"] = round(novelty, 3)
            evidence["mert_model"] = MERT_MODEL_ID
            evidence["mert_window_sec"] = _WINDOW_SECONDS
            item["evidence"] = evidence
            rescored.append(item)
        updated[group] = sort_point_candidates(rescored, limit=8)
    for group in ("tl", "pl"):
        items = updated.get(group, [])
        if not items:
            continue
        windows: List[np.ndarray] = []
        for item in items:
            start = float(item.get("start", 0.0))
            end = float(item.get("end", start))
            windows.append(_window(mono, sample_rate, end - _WINDOW_SECONDS, _WINDOW_SECONDS))
            windows.append(_window(mono, sample_rate, start, _WINDOW_SECONDS))
        embeddings = _embed_windows(windows, feature_extractor, model, torch)
        rescored: List[Dict[str, object]] = []
        for index, item in enumerate(items):
            before_end = embeddings[index * 2]
            after_start = embeddings[index * 2 + 1]
            similarity = _cosine(before_end, after_start)
            item["score"] = _combined_score(float(item.get("score", 0.0)), similarity)
            item["why"] = f"{item.get('why', 'loop candidate')} · MERT seam similarity"
            evidence = dict(item.get("evidence") or {})
            providers = list(evidence.get("providers") or [])
            if "mert" not in providers:
                providers.append("mert")
            evidence["providers"] = providers
            evidence["mert_similarity"] = round(similarity, 3)
            evidence["mert_model"] = MERT_MODEL_ID
            evidence["mert_window_sec"] = _WINDOW_SECONDS
            item["evidence"] = evidence
            rescored.append(item)
        updated[group] = (
            sort_post_loop_candidates(rescored, limit=8)
            if group == "pl"
            else sort_track_loop_candidates(rescored, limit=_TRACK_LOOP_CANDIDATE_LIMIT)
        )
    return updated


def _embed_windows(windows: List[np.ndarray], feature_extractor, model, torch) -> List[np.ndarray]:
    out: List[np.ndarray] = []
    for index in range(0, len(windows), _BATCH_SIZE):
        batch = windows[index : index + _BATCH_SIZE]
        inputs = feature_extractor(
            batch,
            sampling_rate=int(getattr(feature_extractor, "sampling_rate", 24000)),
            return_tensors="pt",
            padding=True,
        )
        device = next(model.parameters()).device
        inputs = {key: value.to(device) for key, value in inputs.items()}
        with torch.inference_mode():
            result = model(**inputs, output_hidden_states=True)
        hidden = result.last_hidden_state
        pooled = hidden.mean(dim=1).detach().cpu().numpy().astype(np.float32)
        out.extend([pooled[row] for row in range(pooled.shape[0])])
    return out


def _window(mono: np.ndarray, sample_rate: int, start: float, duration: float) -> np.ndarray:
    length = max(1, int(round(duration * sample_rate)))
    start_index = int(round(start * sample_rate))
    out = np.zeros(length, dtype=np.float32)
    source_start = max(0, start_index)
    source_end = min(mono.size, start_index + length)
    if source_end <= source_start:
        return out
    target_start = max(0, -start_index)
    copied = source_end - source_start
    out[target_start : target_start + copied] = mono[source_start:source_end]
    return out


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)
    value = float(np.dot(a, b) / denom)
    return max(0.0, min(1.0, (value + 1.0) / 2.0))


def _combined_score(base: float, similarity: float) -> float:
    return round(min(0.95, base * 0.62 + similarity * 0.38), 3)


def _combined_point_score(base: float, novelty: float) -> float:
    return round(min(0.95, base * 0.68 + novelty * 0.32), 3)
