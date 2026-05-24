from __future__ import annotations

import contextlib
import io
import os
import sys
import warnings
from pathlib import Path
from time import perf_counter
from typing import Dict, Iterable, List, Optional, Tuple

from ..generation.ranker import sort_point_candidates
from ..generation.segments import normalize_segments
from ..schema import ProviderStatus, clamp_time, point_candidate
from .baseline_mir import track_start_opening_readiness
from .diagnostics import ProviderTimer, torch_model_runtime
from .hf_download import download_hf_snapshot, remove_invalid_repo_dir
from .runtime import cache_has_any, module_exists, package_version, torch_device

SONGFORMER_MODEL_ID = "ASLP-lab/SongFormer"
_CACHE_SUBDIR = "songformer"
_REPO_SUBDIR = "repo"
_REQUIRED_MODULES = (
    "torch",
    "transformers",
    "huggingface_hub",
    "safetensors",
    "librosa",
    "ema_pytorch",
    "loguru",
    "muq",
    "omegaconf",
    "x_transformers",
    "msaf",
)
_ALLOW_PATTERNS = (
    "config.json",
    "configuration_songformer.py",
    "modeling_songformer.py",
    "model.py",
    "model_config.py",
    "model.safetensors",
    "msd_stats.json",
    "muq_config2.json",
    "dataset/*.py",
    "postprocessing/*.py",
    "musicfm/model/*.py",
    "musicfm/modules/*.py",
)


def check(model_dir: Path, enabled: bool) -> ProviderStatus:
    if not enabled:
        return ProviderStatus(name="songformer", status="disabled")
    missing_modules = [name for name in _REQUIRED_MODULES if not module_exists(name)]
    repo_dir = _ready_repo_dir(model_dir)
    cache_ready = repo_dir is not None
    version = _version()
    if not missing_modules and cache_ready:
        return ProviderStatus(
            name="songformer",
            status="ready",
            version=version,
            device=torch_device(),
        )
    if not missing_modules or cache_ready:
        missing = []
        if missing_modules:
            missing.append("modules: " + ", ".join(missing_modules))
        if not cache_ready:
            missing.append(f"local {SONGFORMER_MODEL_ID} cache")
        return ProviderStatus(
            name="songformer",
            status="partial",
            version=version,
            device=torch_device(),
            warnings=[
                "SongFormer is partially installed; missing "
                + "; ".join(missing)
                + ". Structure labels are falling back to baseline/MERT evidence."
            ],
        )
    return ProviderStatus(
        name="songformer",
        status="missing",
        version=f"{SONGFORMER_MODEL_ID} not cached",
        warnings=[
            f"SongFormer dependencies/cache are not installed under {_repo_dir(model_dir)}; "
            "structure labels are falling back to baseline/MERT evidence."
        ],
    )


def warmup(model_dir: Path) -> ProviderStatus:
    started = perf_counter()
    status = check(model_dir, True)
    missing_modules = [name for name in _REQUIRED_MODULES if not module_exists(name)]
    if missing_modules:
        status.status = "missing"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [
            "SongFormer Warmup requires uv-installed dependencies. Sync `ai-songformer` "
            f"with a torch extra first. Missing: {', '.join(missing_modules)}"
        ]
        return status
    try:
        repo_dir = _ensure_repo(model_dir)
        with _quiet_model_logs():
            _load_model(repo_dir, device="cpu")
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [f"SongFormer Warmup failed: {type(exc).__name__}: {exc}"]
        return status
    status = check(model_dir, True)
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return status


def analyze_segments(
    source: Path,
    *,
    model_dir: Path,
) -> Dict[str, object]:
    timer = ProviderTimer()
    with timer.stage("check"):
        status = check(model_dir, True)
    runtime: Dict[str, object] = {"requested_device": torch_device()}
    forward_profile: Dict[str, object] = {"stages": [], "unattributed_ms": 0}
    if status.status != "ready":
        status.runtime_ms = timer.elapsed_ms()
        return {
            "status": status,
            "segments": [],
            "runtime": runtime,
            "timings": timer.snapshot(total_ms=status.runtime_ms),
            "warnings": list(status.warnings),
        }
    try:
        repo_dir = _ready_repo_dir(model_dir) or _repo_dir(model_dir)
        with _quiet_model_logs():
            with timer.stage("load_model"):
                model = _load_model(repo_dir, device=torch_device())
            with timer.stage("runtime_probe"):
                runtime = _songformer_runtime(model, requested_device=torch_device())
            autocast_config = _songformer_autocast_config(model)
            runtime.update(_songformer_autocast_runtime(autocast_config))
            forward_started = perf_counter()
            with timer.stage("forward_total"):
                with _SongFormerForwardProfiler(model, autocast_config=autocast_config) as profiler:
                    raw_segments = model(str(source))
            forward_total_ms = int(round((perf_counter() - forward_started) * 1000))
            forward_profile = profiler.snapshot(total_ms=forward_total_ms)
            runtime.update(profiler.metadata)
        with timer.stage("normalize_segments"):
            segments = normalize_segments(raw_segments, "songformer", 0.78)
    except Exception as exc:
        status.status = "error"
        status.runtime_ms = timer.elapsed_ms()
        status.warnings = [
            f"SongFormer analysis failed; baseline/MERT structure evidence is being used. {type(exc).__name__}: {exc}"
        ]
        timings = timer.snapshot(total_ms=status.runtime_ms)
        timings["forward_stages"] = forward_profile.get("stages", [])
        timings["forward_unattributed_ms"] = forward_profile.get("unattributed_ms", 0)
        return {
            "status": status,
            "segments": [],
            "runtime": runtime,
            "timings": timings,
            "warnings": list(status.warnings),
        }
    status.runtime_ms = timer.elapsed_ms()
    timings = timer.snapshot(total_ms=status.runtime_ms)
    timings["forward_stages"] = forward_profile.get("stages", [])
    timings["forward_unattributed_ms"] = forward_profile.get("unattributed_ms", 0)
    return {
        "status": status,
        "segments": segments,
        "runtime": runtime,
        "timings": timings,
        "warnings": [],
    }


def add_structure_point_candidates(
    candidates: Dict[str, List[Dict[str, object]]],
    segments: Iterable[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
) -> Dict[str, List[Dict[str, object]]]:
    out = {key: list(value) for key, value in candidates.items()}
    normalized = [item for item in segments if _segment_duration(item) >= 1.0]
    out["td"] = _add_trackdrop_structure_candidates(
        out.get("td", []),
        normalized,
        grid=grid,
        duration=duration,
    )
    out["pd"] = _add_postdrop_structure_candidates(
        out.get("pd", []),
        normalized,
        grid=grid,
        duration=duration,
    )
    return out


def _add_trackdrop_structure_candidates(
    existing: List[Dict[str, object]],
    segments: Iterable[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
) -> List[Dict[str, object]]:
    additions: List[Dict[str, object]] = []
    marker = "TrackDrop"
    segment_list = list(segments)
    intro_cap = trackdrop_intro_cap(segment_list, duration)
    additions.extend(
        _short_intro_trackdrop_candidates(segment_list, grid=grid, duration=duration, marker=marker)
    )
    for segment in segment_list:
        start = float(segment.get("start", 0.0))
        if not (0.0 <= start <= duration * 0.55):
            continue
        if intro_cap is not None and start > intro_cap:
            continue
        label = str(segment.get("label") or "segment")
        early_kickoff = _is_early_track_start(label, start, duration)
        if not early_kickoff:
            continue
        label_score = _trackdrop_label_score(label)
        opening_readiness = track_start_opening_readiness(start, duration) if early_kickoff else 1.0
        if early_kickoff and label_score <= 0.0:
            label_score = 0.95 * opening_readiness
        if label_score <= 0.0:
            continue
        aligned, delta_ms = _align_to_downbeat(start, grid, duration)
        position = _trackdrop_position_prior(aligned, duration)
        score = min(0.93, 0.44 + label_score * 0.28 + position * 0.16)
        track_start_role = (
            "recognizable_intro_base_kickoff"
            if early_kickoff and opening_readiness >= 0.7
            else None
        )
        additions.append(
            point_candidate(
                aligned,
                score,
                f"{marker} · SongFormer {'intro/base kickoff' if early_kickoff else label + ' boundary'}",
                {
                    "marker": marker,
                    "providers": ["songformer"],
                    "quality": "ai_structure",
                    "songformer_label": label,
                    "track_start_role": track_start_role,
                    "track_start_opening_readiness": (
                        round(opening_readiness, 3) if early_kickoff else None
                    ),
                    "segment_start": round(start, 3),
                    "segment_end": round(float(segment.get("end", start)), 3),
                    "nearest_downbeat_delta_ms": delta_ms,
                },
            )
        )
    additions.extend(
        _long_intro_trackdrop_candidates(segment_list, grid=grid, duration=duration, marker=marker)
    )
    return _dedupe_points([*existing, *additions], limit=8) if additions else existing


def trackdrop_intro_cap(segments: Iterable[Dict[str, object]], duration: float) -> Optional[float]:
    bounds = _initial_intro_bounds(list(segments), duration)
    if bounds is None:
        return None
    return bounds[1]


def _add_postdrop_structure_candidates(
    existing: List[Dict[str, object]],
    segments: Iterable[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
) -> List[Dict[str, object]]:
    additions: List[Dict[str, object]] = []
    marker = "PostDrop"
    for segment in segments:
        start = float(segment.get("start", 0.0))
        if not (min(6.0, duration * 0.08) <= start <= duration * 0.98):
            continue
        label = str(segment.get("label") or "segment")
        label_score = _postdrop_label_score(label)
        if label_score <= 0.0:
            continue
        for raw_time, role, role_bonus in _postdrop_segment_point_times(segment, grid, duration):
            aligned, delta_ms = _align_to_downbeat(raw_time, grid, duration)
            position = _postdrop_position_prior(aligned / duration if duration > 0 else 0.0)
            score = min(0.95, 0.42 + label_score * 0.30 + position * 0.20 + role_bonus)
            additions.append(
                point_candidate(
                    aligned,
                    score,
                    _postdrop_structure_why(marker, label, role),
                    {
                        "marker": marker,
                        "providers": ["songformer"],
                        "quality": "ai_structure",
                        "songformer_label": label,
                        "songformer_point_role": role,
                        "segment_start": round(start, 3),
                        "segment_end": round(float(segment.get("end", start)), 3),
                        "nearest_downbeat_delta_ms": delta_ms,
                    },
                )
            )
    return _dedupe_points([*existing, *additions], limit=8) if additions else existing


def _download_repo(model_dir: Path) -> Path:
    repo_dir = _repo_dir(model_dir)
    return download_hf_snapshot(
        repo_id=SONGFORMER_MODEL_ID,
        repo_type="model",
        local_dir=repo_dir,
        allow_patterns=list(_ALLOW_PATTERNS),
    )


def _ensure_repo(model_dir: Path) -> Path:
    ready = _ready_repo_dir(model_dir)
    if ready is not None:
        return ready
    repo_dir = _repo_dir(model_dir)
    if repo_dir.exists():
        remove_invalid_repo_dir(repo_dir, provider_dir=_provider_dir(model_dir))
    return _download_repo(model_dir)


def _load_model(repo_dir: Path, *, device: str) -> object:
    import torch

    if str(repo_dir) not in sys.path:
        sys.path.insert(0, str(repo_dir))
    os.environ["SONGFORMER_LOCAL_DIR"] = str(repo_dir)
    from configuration_songformer import SongFormerConfig
    from modeling_songformer import SongFormerModel
    from safetensors.torch import load_file

    target_device = "cuda" if device == "cuda" and torch.cuda.is_available() else "cpu"
    with contextlib.redirect_stdout(io.StringIO()):
        config = SongFormerConfig.from_pretrained(str(repo_dir))
        model = SongFormerModel(config)
        state = load_file(str(repo_dir / "model.safetensors"), device="cpu")
        model.load_state_dict(state, strict=True)
    model = model.to(target_device).eval()
    compile_strategy = _torch_compile_strategy()
    if target_device == "cuda" and compile_strategy != "off":
        _compile_songformer_hot_path(model, torch, compile_strategy)
    else:
        model._fh_radio_studio_torch_compile = {"enabled": False, "strategy": compile_strategy}  # type: ignore[attr-defined]
    return model


def _torch_compile_strategy() -> str:
    value = os.environ.get("FH_RADIO_STUDIO_SONGFORMER_TORCH_COMPILE", "off").strip().lower()
    if value in {"1", "true", "yes", "on", "musicfm"}:
        return "musicfm"
    if value in {"muq", "all"}:
        return value
    return "off"


def _compile_songformer_hot_path(model: object, torch_module: object, strategy: str) -> None:
    backend = "inductor"
    options = {"triton.cudagraphs": False}
    modules: List[str] = []
    if strategy in {"muq", "all"}:
        model.muq = torch_module.compile(model.muq, backend=backend, options=options)  # type: ignore[attr-defined]
        modules.append("muq")
    if strategy in {"musicfm", "all"}:
        model.musicfm.encoder = torch_module.compile(  # type: ignore[attr-defined]
            model.musicfm.encoder,  # type: ignore[attr-defined]
            backend=backend,
            options=options,
        )
        modules.append("musicfm.encoder")
    model._fh_radio_studio_torch_compile = {  # type: ignore[attr-defined]
        "enabled": True,
        "strategy": strategy,
        "backend": backend,
        "mode": "default",
        "options": options,
        "modules": modules,
    }


def _songformer_runtime(model: object, *, requested_device: str) -> Dict[str, object]:
    device = "unknown"
    try:
        parameter = next(model.parameters())  # type: ignore[attr-defined]
        device = str(parameter.device)
    except Exception:
        pass
    return torch_model_runtime(
        model,
        backend="python_api",
        requested_device=requested_device,
        device=device,
        inference_precision="float32",
        no_grad_enabled=True,
        torch_compile=getattr(model, "_fh_radio_studio_torch_compile", {"enabled": False}),
    )


def _songformer_autocast_config(model: object) -> Dict[str, object]:
    value = os.environ.get("FH_RADIO_STUDIO_SONGFORMER_AUTOCAST", "bf16").strip().lower()
    if value in {"0", "false", "no", "none", "off", ""}:
        return {"enabled": False, "strategy": "off"}
    try:
        import torch

        parameter = next(model.parameters())  # type: ignore[attr-defined]
        if parameter.device.type != "cuda":
            return {"enabled": False, "strategy": value, "reason": "non_cuda_device"}
        if value in {"bf16", "bfloat16"}:
            if not torch.cuda.is_bf16_supported():
                return {"enabled": False, "strategy": "bf16", "reason": "bf16_not_supported"}
            return {
                "enabled": True,
                "strategy": "bf16",
                "dtype": torch.bfloat16,
                "cache_enabled": _autocast_cache_enabled(),
            }
        if value in {"fp16", "float16", "half", "1", "true", "yes", "on"}:
            return {
                "enabled": True,
                "strategy": "fp16",
                "dtype": torch.float16,
                "cache_enabled": _autocast_cache_enabled(),
            }
    except Exception as exc:
        return {"enabled": False, "strategy": value, "reason": f"{type(exc).__name__}: {exc}"}
    return {"enabled": False, "strategy": value, "reason": "unknown_strategy"}


def _songformer_autocast_runtime(config: Dict[str, object]) -> Dict[str, object]:
    dtype = config.get("dtype")
    return {
        "autocast_enabled": bool(config.get("enabled")),
        "autocast_strategy": config.get("strategy", "off"),
        "autocast_dtype": str(dtype).replace("torch.", "") if dtype is not None else None,
        "autocast_cache_enabled": config.get("cache_enabled"),
        "autocast_scope": "muq.forward and musicfm.get_predictions; selected embeddings cast back to float32",
        "autocast_reason": config.get("reason"),
    }


def _autocast_cache_enabled() -> bool:
    value = os.environ.get("FH_RADIO_STUDIO_SONGFORMER_AUTOCAST_CACHE", "0").strip().lower()
    return value in {"1", "true", "yes", "on"}


class _SongFormerForwardProfiler:
    _CUDA_EVENT_STAGES = {
        "muq.forward",
        "musicfm.get_predictions",
        "songformer.infer",
    }

    def __init__(self, model: object, *, autocast_config: Dict[str, object]) -> None:
        self._model = model
        self._torch = _torch_for_cuda_events(model)
        self._autocast_config = autocast_config
        self._records: Dict[str, Dict[str, object]] = {}
        self._order: List[str] = []
        self._restore: List[Tuple[object, str, object]] = []
        self.metadata: Dict[str, object] = {
            "empty_cache_policy": "disabled_provider_uses_torch_caching_allocator",
            "forward_timer": "cuda_events" if self._torch is not None else "wall_clock",
            "encoder_output_cast_policy": "selected_hidden_state_10_to_float32",
        }

    def __enter__(self) -> "_SongFormerForwardProfiler":
        modeling = sys.modules.get("modeling_songformer")
        if modeling is not None:
            librosa_module = getattr(modeling, "librosa", None)
            self._wrap_callable(
                librosa_module, "load", "librosa.load", self._record_librosa_metadata
            )
            self._wrap_callable(
                modeling, "postprocess_functional_structure", "postprocess.functional_structure"
            )
            self._wrap_callable(modeling, "rule_post_processing", "postprocess.rule")
            torch_module = getattr(modeling, "torch", None)
            cuda_module = getattr(torch_module, "cuda", None)
            self._disable_empty_cache(cuda_module)
        self._wrap_callable(getattr(self._model, "muq", None), "forward", "muq.forward")
        self._wrap_callable(
            getattr(self._model, "musicfm", None),
            "get_predictions",
            "musicfm.get_predictions",
        )
        self._wrap_callable(getattr(self._model, "songformer", None), "infer", "songformer.infer")
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:  # type: ignore[no-untyped-def]
        for owner, attr, original in reversed(self._restore):
            setattr(owner, attr, original)
        self._restore.clear()

    def snapshot(self, *, total_ms: int) -> Dict[str, object]:
        if self._torch is not None:
            self._torch.cuda.synchronize()
        stages = []
        for name in self._order:
            record = self._records[name]
            cpu_runtime_ms = float(record["cpu_runtime_ms"])
            cuda_events = list(record.get("cuda_events") or [])
            if cuda_events:
                runtime_ms = sum(float(start.elapsed_time(end)) for start, end in cuda_events)
                item = {
                    "name": name,
                    "runtime_ms": int(round(runtime_ms)),
                    "cpu_runtime_ms": int(round(cpu_runtime_ms)),
                    "calls": int(record["calls"]),
                }
            else:
                item = {
                    "name": name,
                    "runtime_ms": int(round(cpu_runtime_ms)),
                    "calls": int(record["calls"]),
                }
            stages.append(item)
        measured_ms = sum(int(item["runtime_ms"]) for item in stages)
        return {
            "total_ms": int(total_ms),
            "stages": stages,
            "unattributed_ms": max(0, int(total_ms) - measured_ms),
        }

    def _wrap_callable(self, owner: object, attr: str, name: str, metadata=None) -> None:  # type: ignore[no-untyped-def]
        if owner is None:
            return
        original = getattr(owner, attr, None)
        if not callable(original):
            return
        use_cuda_event = self._torch is not None and name in self._CUDA_EVENT_STAGES

        def timed(*args, **kwargs):  # type: ignore[no-untyped-def]
            event_pair = None
            if use_cuda_event:
                start_event = self._torch.cuda.Event(enable_timing=True)
                end_event = self._torch.cuda.Event(enable_timing=True)
                start_event.record()
                event_pair = (start_event, end_event)
            started = perf_counter()
            with self._maybe_autocast(name):
                result = original(*args, **kwargs)
            result = self._maybe_cast_encoder_output(name, result)
            cpu_runtime_ms = (perf_counter() - started) * 1000.0
            if event_pair is not None:
                event_pair[1].record()
            self._record(name, cpu_runtime_ms, event_pair)
            if metadata is not None:
                metadata(result)
            return result

        setattr(owner, attr, timed)
        self._restore.append((owner, attr, original))

    @contextlib.contextmanager
    def _maybe_autocast(self, name: str):
        if (
            self._torch is None
            or not bool(self._autocast_config.get("enabled"))
            or name not in {"muq.forward", "musicfm.get_predictions"}
        ):
            yield
            return
        dtype = self._autocast_config.get("dtype")
        cache_enabled = bool(self._autocast_config.get("cache_enabled"))
        with self._torch.autocast(device_type="cuda", dtype=dtype, cache_enabled=cache_enabled):
            yield

    def _maybe_cast_encoder_output(self, name: str, result: object) -> object:
        if not bool(self._autocast_config.get("enabled")):
            return result
        if name == "muq.forward" and isinstance(result, dict):
            hidden_states = result.get("hidden_states")
            result["hidden_states"] = _cast_hidden_state(hidden_states, 10)
        elif name == "musicfm.get_predictions" and isinstance(result, tuple) and len(result) >= 2:
            items = list(result)
            items[1] = _cast_hidden_state(items[1], 10)
            result = tuple(items)
        return result

    def _disable_empty_cache(self, cuda_module: object) -> None:
        if cuda_module is None:
            return
        original = getattr(cuda_module, "empty_cache", None)
        if not callable(original):
            return

        def disabled_empty_cache(*args, **kwargs):  # type: ignore[no-untyped-def]
            self._record("torch.cuda.empty_cache_disabled", 0.0, None)
            return None

        setattr(cuda_module, "empty_cache", disabled_empty_cache)
        self._restore.append((cuda_module, "empty_cache", original))

    def _record(self, name: str, cpu_runtime_ms: float, cuda_event_pair: object) -> None:
        if name not in self._records:
            self._records[name] = {
                "name": name,
                "cpu_runtime_ms": 0.0,
                "calls": 0,
                "cuda_events": [],
            }
            self._order.append(name)
        record = self._records[name]
        record["cpu_runtime_ms"] = float(record["cpu_runtime_ms"]) + cpu_runtime_ms
        record["calls"] = int(record["calls"]) + 1
        if cuda_event_pair is not None:
            events = list(record.get("cuda_events") or [])
            events.append(cuda_event_pair)
            record["cuda_events"] = events

    def _record_librosa_metadata(self, result: object) -> None:
        if not isinstance(result, tuple) or len(result) < 2:
            return
        waveform, sample_rate = result[0], result[1]
        self.metadata["audio_dtype"] = str(getattr(waveform, "dtype", "unknown"))
        self.metadata["audio_shape"] = _shape_list(waveform)
        try:
            self.metadata["audio_sample_rate"] = int(sample_rate)
        except (TypeError, ValueError):
            pass


def _shape_list(value: object) -> List[int]:
    shape = getattr(value, "shape", None)
    if shape is None:
        return []
    try:
        return [int(item) for item in shape]
    except TypeError:
        return []


def _cast_hidden_state(hidden_states: object, index: int) -> object:
    if not isinstance(hidden_states, (list, tuple)) or len(hidden_states) <= index:
        return hidden_states
    values = list(hidden_states)
    tensor = values[index]
    if hasattr(tensor, "float"):
        values[index] = tensor.float()
    return tuple(values) if isinstance(hidden_states, tuple) else values


def _torch_for_cuda_events(model: object) -> Optional[object]:
    try:
        import torch

        parameter = next(model.parameters())  # type: ignore[attr-defined]
        if getattr(parameter, "device", None) is not None and parameter.device.type == "cuda":
            return torch
    except Exception:
        pass
    return None


@contextlib.contextmanager
def _quiet_model_logs():
    with (
        contextlib.redirect_stdout(io.StringIO()),
        contextlib.redirect_stderr(io.StringIO()),
        warnings.catch_warnings(),
    ):
        warnings.simplefilter("ignore")
        yield


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
        and (repo_dir / "model.safetensors").is_file()
        and (repo_dir / "modeling_songformer.py").is_file()
        and cache_has_any(repo_dir, ("musicfm/model/*.py",))
    )


def _version() -> str:
    transformers_version = package_version("transformers") or "unknown"
    return f"{SONGFORMER_MODEL_ID}; transformers {transformers_version}"


def _segment_duration(segment: Dict[str, object]) -> float:
    return max(0.0, float(segment.get("end", 0.0)) - float(segment.get("start", 0.0)))


def _trackdrop_label_score(label: str) -> float:
    text = label.lower().replace("-", "").replace("_", "")
    if "silence" in text:
        return 0.0
    if "intro" in text or "outro" in text or "ending" in text:
        return 0.0
    if "chorus" in text or "refrain" in text or "hook" in text:
        return 1.0
    if "prechorus" in text or "build" in text or "mainriff" in text:
        return 0.82
    if "inst" in text or "solo" in text or "break" in text:
        return 0.7
    if "verse" in text:
        return 0.58
    if "bridge" in text or "interlude" in text or "transition" in text:
        return 0.5
    return 0.35


def _postdrop_label_score(label: str) -> float:
    text = label.lower().replace("-", "").replace("_", "")
    if "silence" in text:
        return 0.0
    if "chorus" in text or "refrain" in text or "hook" in text:
        return 1.0
    if "prechorus" in text or "build" in text or "mainriff" in text:
        return 0.82
    if "bridge" in text or "interlude" in text or "transition" in text:
        return 0.78
    if "inst" in text or "solo" in text or "break" in text:
        return 0.7
    if "outro" in text or "ending" in text:
        return 0.55
    if "verse" in text:
        return 0.45
    return 0.35


def _trackdrop_position_prior(time: float, duration: float) -> float:
    if duration <= 0:
        return 0.0
    ratio = clamp_time(time, duration) / duration
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


def _postdrop_segment_point_times(
    segment: Dict[str, object],
    grid: Dict[str, object],
    duration: float,
) -> List[Tuple[float, str, float]]:
    start = float(segment.get("start", 0.0))
    end = float(segment.get("end", start))
    out: List[Tuple[float, str, float]] = [(start, "boundary", 0.06)]
    if duration <= 0 or end <= start or start < duration * 0.45:
        return out
    label = str(segment.get("label") or "")
    if not _is_postdrop_payoff_label(label):
        return out
    inner = start + (end - start) * 0.55
    if inner <= duration * 0.9:
        aligned, _ = _align_to_downbeat(inner, grid, duration)
        if abs(aligned - start) >= 2.0 and aligned < end - 1.0:
            out.append((aligned, "payoff_downbeat", 0.10))
    return out


def _is_postdrop_payoff_label(label: str) -> bool:
    text = label.lower().replace("-", "").replace("_", "")
    return any(
        token in text
        for token in (
            "chorus",
            "refrain",
            "hook",
            "bridge",
            "interlude",
            "transition",
            "solo",
            "break",
        )
    )


def _postdrop_structure_why(
    marker: str,
    label: str,
    role: str,
) -> str:
    if role == "payoff_downbeat":
        return f"{marker} · SongFormer {label} payoff downbeat"
    return f"{marker} · SongFormer {label} boundary"


def _short_intro_trackdrop_candidates(
    segments: List[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
    marker: str,
) -> List[Dict[str, object]]:
    bounds = _initial_intro_bounds(segments, duration)
    if bounds is None:
        return _no_intro_trackdrop_candidates(segments, grid=grid, duration=duration, marker=marker)
    intro_start, intro_end, intro_segments = bounds
    if intro_start > 0.35:
        return []
    intro_duration = intro_end - intro_start
    threshold = _short_intro_threshold(grid, duration)
    if intro_duration <= 0 or intro_duration > threshold:
        return []
    next_segment = _next_segment_after(segments, intro_end)
    next_label = str(next_segment.get("label") or "") if next_segment is not None else ""
    if next_label and (
        _is_silence_label(next_label)
        or "outro" in next_label.lower()
        or "ending" in next_label.lower()
    ):
        return []

    confidence_values = [
        max(0.0, min(1.0, float(segment.get("confidence", 0.78)))) for segment in intro_segments
    ]
    confidence = sum(confidence_values) / len(confidence_values) if confidence_values else 0.78
    shortness = max(0.0, min(1.0, (threshold - intro_duration) / max(threshold, 0.001)))
    score = min(0.94, 0.82 + confidence * 0.06 + shortness * 0.05)
    downbeats = [float(value) for value in grid.get("downbeats", [])]
    nearest = min(downbeats, key=lambda value: abs(value)) if downbeats else 0.0
    delta_ms = int(round(-nearest * 1000.0)) if abs(nearest) <= 0.35 else None

    return [
        point_candidate(
            0.0,
            score,
            f"{marker} · SongFormer short merged intro start",
            {
                "marker": marker,
                "providers": ["songformer"],
                "quality": "ai_structure",
                "songformer_label": "intro",
                "songformer_point_role": "short_intro_start",
                "track_start_role": "short_intro_start",
                "track_start_policy": "include_zero_for_short_intro",
                "merged_intro_start": round(intro_start, 3),
                "merged_intro_end": round(intro_end, 3),
                "merged_intro_duration": round(intro_duration, 3),
                "merged_intro_segments": len(intro_segments),
                "short_intro_threshold": round(threshold, 3),
                "next_segment_label": next_label or None,
                "nearest_downbeat_delta_ms": delta_ms,
            },
        )
    ]


def _no_intro_trackdrop_candidates(
    segments: List[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
    marker: str,
) -> List[Dict[str, object]]:
    first_segment = _first_playable_segment(segments)
    if first_segment is None:
        return []
    start = float(first_segment.get("start", 0.0))
    if start > 0.35:
        return []
    label = str(first_segment.get("label") or "segment")
    if not _is_early_track_start(label, start, duration):
        return []

    label_score = max(0.35, _trackdrop_label_score(label))
    confidence = max(0.0, min(1.0, float(first_segment.get("confidence", 0.78))))
    score = min(0.94, 0.82 + label_score * 0.06 + confidence * 0.05)
    downbeats = [float(value) for value in grid.get("downbeats", [])]
    nearest = min(downbeats, key=lambda value: abs(value)) if downbeats else 0.0
    delta_ms = int(round(-nearest * 1000.0)) if abs(nearest) <= 0.35 else None

    return [
        point_candidate(
            0.0,
            score,
            f"{marker} · SongFormer no-intro start",
            {
                "marker": marker,
                "providers": ["songformer"],
                "quality": "ai_structure",
                "songformer_label": label,
                "songformer_point_role": "no_intro_start",
                "track_start_role": "no_intro_start",
                "track_start_policy": "include_zero_for_no_intro",
                "segment_start": round(start, 3),
                "segment_end": round(float(first_segment.get("end", start)), 3),
                "nearest_downbeat_delta_ms": delta_ms,
            },
        )
    ]


def _long_intro_trackdrop_candidates(
    segments: List[Dict[str, object]],
    *,
    grid: Dict[str, object],
    duration: float,
    marker: str,
) -> List[Dict[str, object]]:
    runway = _initial_intro_runway(segments, duration)
    if runway is None:
        return []
    intro_start, intro_end, intro_segments, threshold = runway
    downbeats = [float(value) for value in grid.get("downbeats", [])]
    if not downbeats:
        return []
    bar_step = _median_step(downbeats)
    normal_window_end = _normal_intro_kickoff_latest(duration)
    guard = max(1.5, min(6.0, bar_step * 0.75))
    search_start = max(normal_window_end, intro_start + min(8.0, (intro_end - intro_start) * 0.25))
    search_end = min(intro_end - guard, duration * 0.55)
    if search_end <= search_start:
        return []

    scored: List[Tuple[float, float, Dict[str, object]]] = []
    for downbeat in downbeats:
        if downbeat < search_start or downbeat > search_end:
            continue
        segment = _segment_at(intro_segments, downbeat)
        if segment is None:
            continue
        segment_start = float(segment.get("start", 0.0))
        segment_end = float(segment.get("end", segment_start))
        if segment_end <= segment_start:
            continue
        local_ratio = (downbeat - segment_start) / (segment_end - segment_start)
        runway_ratio = (downbeat - intro_start) / max(1.0, intro_end - intro_start)
        local_payoff = max(0.0, 1.0 - abs(local_ratio - 0.55) / 0.38)
        runway_payoff = max(0.0, 1.0 - abs(runway_ratio - 0.82) / 0.28)
        end_clearance = max(0.0, min(1.0, (intro_end - downbeat) / max(guard * 2.5, 1.0)))
        confidence = max(0.0, min(1.0, float(segment.get("confidence", 0.78))))
        score = (
            0.64
            + local_payoff * 0.13
            + runway_payoff * 0.10
            + end_clearance * 0.04
            + confidence * 0.05
        )
        evidence = {
            "marker": marker,
            "providers": ["songformer"],
            "quality": "ai_structure",
            "songformer_label": str(segment.get("label") or "intro"),
            "songformer_point_role": "long_intro_downbeat",
            "track_start_role": "recognizable_intro_base_kickoff",
            "long_intro_start": round(intro_start, 3),
            "long_intro_end": round(intro_end, 3),
            "long_intro_threshold": round(threshold, 3),
            "long_intro_search_start": round(search_start, 3),
            "long_intro_search_end": round(search_end, 3),
            "long_intro_local_ratio": round(local_ratio, 3),
            "long_intro_runway_ratio": round(runway_ratio, 3),
            "segment_start": round(segment_start, 3),
            "segment_end": round(segment_end, 3),
            "nearest_downbeat_delta_ms": 0,
        }
        scored.append((score, downbeat, evidence))

    scored.sort(reverse=True)
    selected: List[Dict[str, object]] = []
    min_gap = max(bar_step * 2.0, 4.0)
    for score, downbeat, evidence in scored:
        if any(abs(downbeat - float(item.get("t", 0.0))) < min_gap for item in selected):
            continue
        selected.append(
            point_candidate(
                downbeat,
                min(0.94, score),
                f"{marker} · SongFormer long intro downbeat",
                evidence,
            )
        )
        if len(selected) >= 3:
            break
    return selected


def _initial_intro_runway(
    segments: List[Dict[str, object]],
    duration: float,
) -> Optional[Tuple[float, float, List[Dict[str, object]], float]]:
    bounds = _initial_intro_bounds(segments, duration)
    if bounds is None:
        return None
    intro_start, intro_end, intro_segments = bounds
    threshold = _long_intro_threshold(duration)
    if intro_end - intro_start < threshold:
        return None
    if len(intro_segments) < 2 and intro_end - intro_start < threshold + 8.0:
        return None
    return intro_start, intro_end, intro_segments, threshold


def _initial_intro_bounds(
    segments: List[Dict[str, object]],
    duration: float,
) -> Optional[Tuple[float, float, List[Dict[str, object]]]]:
    if duration <= 0:
        return None
    start_window = min(12.0, max(4.0, duration * 0.06))
    intro_start: Optional[float] = None
    intro_end = 0.0
    intro_segments: List[Dict[str, object]] = []
    for segment in sorted(segments, key=lambda item: float(item.get("start", 0.0))):
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        if end <= start:
            continue
        label = str(segment.get("label") or "")
        if _is_silence_label(label):
            if intro_start is None and start <= start_window:
                continue
            if intro_start is not None and start <= intro_end + 1.5:
                intro_end = max(intro_end, end)
                continue
            break
        if not _is_intro_label(label):
            break
        if intro_start is None:
            if start > start_window:
                return None
            intro_start = start
        elif start > intro_end + 1.5:
            break
        intro_end = max(intro_end, end)
        intro_segments.append(segment)
    if intro_start is None or not intro_segments:
        return None
    return intro_start, intro_end, intro_segments


def _long_intro_threshold(duration: float) -> float:
    return max(42.0, duration * 0.16)


def _short_intro_threshold(grid: Dict[str, object], duration: float) -> float:
    downbeats = [float(value) for value in grid.get("downbeats", [])]
    bar_step = _median_step(downbeats) if downbeats else 2.0
    duration_hint = duration * 0.015 if duration > 0 else 0.0
    return max(1.5, min(3.0, max(duration_hint, bar_step * 0.75)))


def _normal_intro_kickoff_latest(duration: float) -> float:
    if duration <= 0:
        return 0.0
    return min(34.0, duration * 0.12)


def _is_intro_label(label: str) -> bool:
    text = label.lower().replace("-", "").replace("_", "")
    return "intro" in text or "opening" in text or "prelude" in text


def _is_silence_label(label: str) -> bool:
    text = label.lower().replace("-", "").replace("_", "")
    return "silence" in text or "silent" in text or "blank" in text


def _segment_at(segments: Iterable[Dict[str, object]], time: float) -> Optional[Dict[str, object]]:
    for segment in segments:
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        if start <= time < end:
            return segment
    return None


def _next_segment_after(
    segments: Iterable[Dict[str, object]], time: float
) -> Optional[Dict[str, object]]:
    following = [
        segment
        for segment in segments
        if float(segment.get("start", 0.0)) >= time - 0.01
        and float(segment.get("end", segment.get("start", 0.0))) > float(segment.get("start", 0.0))
    ]
    if not following:
        return None
    return min(following, key=lambda segment: float(segment.get("start", 0.0)))


def _first_playable_segment(segments: Iterable[Dict[str, object]]) -> Optional[Dict[str, object]]:
    for segment in sorted(segments, key=lambda item: float(item.get("start", 0.0))):
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        if end <= start:
            continue
        label = str(segment.get("label") or "")
        if _is_silence_label(label):
            continue
        return segment
    return None


def _median_step(values: List[float]) -> float:
    diffs = [
        values[index] - values[index - 1]
        for index in range(1, len(values))
        if values[index] > values[index - 1]
    ]
    if not diffs:
        return 2.0
    diffs.sort()
    return float(diffs[len(diffs) // 2])


def _is_early_track_start(label: str, start: float, duration: float) -> bool:
    text = label.lower().replace("-", "").replace("_", "")
    if "silence" in text or "outro" in text or "ending" in text:
        return False
    if duration <= 0:
        return False
    return start >= 0.0 and start <= _normal_intro_kickoff_latest(duration)


def _align_to_downbeat(
    time: float, grid: Dict[str, object], duration: float
) -> Tuple[float, Optional[int]]:
    downbeats = [float(value) for value in grid.get("downbeats", [])]
    if not downbeats:
        return round(clamp_time(time, duration), 3), None
    nearest = min(downbeats, key=lambda value: abs(value - time))
    delta_ms = int(round((time - nearest) * 1000.0))
    if abs(delta_ms) <= 350:
        return round(clamp_time(nearest, duration), 3), delta_ms
    return round(clamp_time(time, duration), 3), delta_ms


def _dedupe_points(
    items: Iterable[Dict[str, object]], *, limit: int = 5
) -> List[Dict[str, object]]:
    best: Dict[int, Dict[str, object]] = {}
    for item in items:
        key = int(round(float(item.get("t", 0.0)) * 10.0))
        current = best.get(key)
        if current is None or float(item.get("score", 0.0)) > float(current.get("score", 0.0)):
            best[key] = item
    return sort_point_candidates(best.values(), limit=limit)
