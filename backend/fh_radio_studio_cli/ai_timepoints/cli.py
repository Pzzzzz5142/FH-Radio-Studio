from __future__ import annotations

import sys
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter
from typing import Dict, Iterable, Iterator, List, Optional

from ..common import die, json
from ..external_tools import find_executable
from .cache import build_cache_manifest, default_model_dir, write_install_manifest
from .generation.ranker import (
    sort_point_candidates,
    sort_post_loop_candidates,
    sort_track_loop_candidates,
)
from .providers import baseline_mir, beat_this, demucs, mert, songformer
from .schema import SCHEMA_VERSION, WRITE_SAMPLE_RATE, ProviderStatus

PROFILES = ("local-base", "local-deep", "local-heavy")
PROGRESS_PREFIX = "FH_RADIO_STUDIO_PROGRESS "
_MIN_POST_LOOP_SECONDS = 20.0
_MIN_POST_LOOP_END_AFTER_POSTDROP_SECONDS = 20.0


PIPELINE_STEPS: List[Dict[str, object]] = [
    {
        "id": "setup",
        "label": "启动与输入检查",
        "detail": "确认源音频、ffmpeg 与模型缓存目录。",
        "provider": None,
        "optional": False,
        "weight": 5,
    },
    {
        "id": "beat_this.check",
        "label": "检查 Beat This",
        "detail": "检查节拍检测 runtime 和 checkpoint。",
        "provider": "beat_this",
        "optional": True,
        "weight": 4,
    },
    {
        "id": "beat_this.analyze",
        "label": "节拍与小节网格",
        "detail": "提取 beat、downbeat、BPM 与网格置信度。",
        "provider": "beat_this",
        "optional": True,
        "weight": 12,
    },
    {
        "id": "baseline_mir.analyze",
        "label": "波形与兜底候选",
        "detail": "读取音频，生成 waveform、基础段落和 TD/PD/TL/PL 候选。",
        "provider": "baseline_mir",
        "optional": False,
        "weight": 18,
    },
    {
        "id": "songformer.check",
        "label": "检查 SongFormer",
        "detail": "检查结构识别模型是否可用。",
        "provider": "songformer",
        "optional": True,
        "weight": 4,
    },
    {
        "id": "songformer.analyze_segments",
        "label": "结构段落识别",
        "detail": "识别 intro、verse、chorus、drop 等自由标签段落。",
        "provider": "songformer",
        "optional": True,
        "weight": 12,
    },
    {
        "id": "songformer.add_point_candidates",
        "label": "结构候选融合",
        "detail": "把段落边界融合进 TD/PD 候选。",
        "provider": "songformer",
        "optional": True,
        "weight": 6,
    },
    {
        "id": "constraints.after_structure",
        "label": "结构后约束",
        "detail": "按游戏时间点规则过滤并重排候选。",
        "provider": None,
        "optional": False,
        "weight": 5,
    },
    {
        "id": "mert.check",
        "label": "检查 MERT",
        "detail": "检查音乐 embedding 模型是否可用。",
        "provider": "mert",
        "optional": True,
        "weight": 4,
    },
    {
        "id": "mert.score_candidates",
        "label": "MERT 候选评分",
        "detail": "用 embedding 评估 loop seam 和候选音乐状态。",
        "provider": "mert",
        "optional": True,
        "weight": 14,
    },
    {
        "id": "constraints.after_mert",
        "label": "MERT 后约束",
        "detail": "吸收 embedding 分数后再次重排候选。",
        "provider": None,
        "optional": False,
        "weight": 3,
    },
    {
        "id": "demucs.check",
        "label": "检查 Demucs",
        "detail": "检查 stem 分离模型是否可用。",
        "provider": "demucs",
        "optional": True,
        "weight": 4,
    },
    {
        "id": "demucs.score_candidates",
        "label": "Demucs stem 证据",
        "detail": "用鼓、低频、人声等 stem 证据强化 drop 和 loop 判断。",
        "provider": "demucs",
        "optional": True,
        "weight": 16,
    },
    {
        "id": "constraints.after_demucs",
        "label": "最终时间约束",
        "detail": "合并 stem 证据并应用最终游戏规则。",
        "provider": None,
        "optional": False,
        "weight": 4,
    },
    {
        "id": "finalize_payload",
        "label": "生成分析结果",
        "detail": "汇总候选、provider 状态、timing 与缓存信息。",
        "provider": None,
        "optional": False,
        "weight": 6,
    },
]

_PIPELINE_STEP_BY_ID = {str(step["id"]): step for step in PIPELINE_STEPS}
_OPTIONAL_PROVIDER_ORDER = ("beat_this", "songformer", "mert", "demucs")
_PROVIDER_CHECK_STEP_IDS = {
    "beat_this": "beat_this.check",
    "songformer": "songformer.check",
    "mert": "mert.check",
    "demucs": "demucs.check",
}


class _ProgressReporter:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled
        self._started: Dict[str, float] = {}

    def plan(self, profile: str, step_ids: Iterable[str]) -> None:
        steps: List[Dict[str, object]] = []
        for step_id in step_ids:
            step = _PIPELINE_STEP_BY_ID.get(step_id)
            if step is not None:
                steps.append({**step, "enabled": True})
        self.emit({"event": "plan", "profile": profile, "steps": steps})

    @contextmanager
    def stage(self, step_id: str) -> Iterator[None]:
        self.started(step_id)
        try:
            yield
        except Exception as exc:
            self.failed(step_id, f"{type(exc).__name__}: {exc}")
            raise
        else:
            self.completed(step_id)

    def started(self, step_id: str) -> None:
        self._started[step_id] = perf_counter()
        self.emit({"event": "step_started", "step_id": step_id})

    def completed(
        self,
        step_id: str,
        *,
        status: str = "done",
        summary: str = "",
        warnings: Optional[List[str]] = None,
        runtime_ms: Optional[int] = None,
    ) -> None:
        started = self._started.pop(step_id, None)
        if runtime_ms is None:
            runtime_ms = int(round((perf_counter() - started) * 1000)) if started is not None else 0
        payload: Dict[str, object] = {
            "event": "step_completed",
            "step_id": step_id,
            "status": status,
            "runtime_ms": runtime_ms,
        }
        if summary:
            payload["summary"] = summary
        if warnings:
            payload["warnings"] = warnings
        self.emit(payload)

    def failed(self, step_id: str, message: str) -> None:
        started = self._started.pop(step_id, None)
        runtime_ms = int(round((perf_counter() - started) * 1000)) if started is not None else 0
        self.emit(
            {
                "event": "step_failed",
                "step_id": step_id,
                "status": "error",
                "runtime_ms": runtime_ms,
                "summary": message,
            }
        )

    def emit(self, payload: Dict[str, object]) -> None:
        if not self.enabled:
            return
        print(
            f"{PROGRESS_PREFIX}{json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}",
            file=sys.stderr,
            flush=True,
        )


class _StageTimer:
    def __init__(self) -> None:
        self._started = perf_counter()
        self._stages: List[Dict[str, object]] = []

    @contextmanager
    def stage(self, name: str) -> Iterator[None]:
        started = perf_counter()
        try:
            yield
        finally:
            self._stages.append(
                {
                    "name": name,
                    "runtime_ms": int(round((perf_counter() - started) * 1000)),
                }
            )

    def snapshot(self) -> Dict[str, object]:
        total_ms = int(round((perf_counter() - self._started) * 1000))
        measured_ms = sum(int(item["runtime_ms"]) for item in self._stages)
        return {
            "total_ms": total_ms,
            "stages": list(self._stages),
            "unattributed_ms": max(0, total_ms - measured_ms),
        }


def _model_dir(value: Optional[str]) -> Path:
    return Path(value).expanduser() if value else default_model_dir()


def _enabled_providers(profile: str) -> Dict[str, bool]:
    deep = profile in ("local-deep", "local-heavy")
    heavy = profile == "local-heavy"
    return {
        "beat_this": deep,
        "songformer": deep,
        "mert": deep,
        "demucs": heavy,
    }


def _enabled_optional_provider_names(profile: str) -> List[str]:
    enabled = _enabled_providers(profile)
    return [name for name in _OPTIONAL_PROVIDER_ORDER if enabled.get(name, False)]


def _deep_statuses(profile: str, model_dir: Path) -> List[ProviderStatus]:
    enabled = _enabled_providers(profile)
    statuses: List[ProviderStatus] = []
    if enabled["beat_this"]:
        statuses.append(beat_this.check(model_dir, True))
    if enabled["songformer"]:
        statuses.append(songformer.check(model_dir, True))
    if enabled["mert"]:
        statuses.append(mert.check(model_dir, True))
    if enabled["demucs"]:
        statuses.append(demucs.check(model_dir, True))
    return statuses


def _status_warnings(statuses: Iterable[ProviderStatus]) -> List[str]:
    warnings: List[str] = []
    for status in statuses:
        warnings.extend(status.warnings)
    return warnings


def _provider_names(statuses: Iterable[ProviderStatus]) -> List[str]:
    return [status.name for status in statuses if status.status != "disabled"]


def _run_timed_stage(timer: _StageTimer, name: str, callback):
    started = perf_counter()
    with timer.stage(name):
        result = callback()
    runtime_ms = int(round((perf_counter() - started) * 1000))
    return result, runtime_ms


def _check_provider(name: str, model_dir: Path) -> ProviderStatus:
    if name == "beat_this":
        return beat_this.check(model_dir, True)
    if name == "songformer":
        return songformer.check(model_dir, True)
    if name == "mert":
        return mert.check(model_dir, True)
    if name == "demucs":
        return demucs.check(model_dir, True)
    raise ValueError(f"Unknown AI Provider: {name}")


def _ready(statuses: Dict[str, ProviderStatus], name: str) -> bool:
    status = statuses.get(name)
    return bool(status and status.status == "ready")


def _check_progress_status(status: ProviderStatus) -> str:
    return "done" if status.status == "ready" else "warning"


def _check_progress_summary(status: ProviderStatus) -> str:
    return "" if status.status == "ready" else f"{status.name} {status.status}"


def _progress_plan_step_ids(profile: str) -> List[str]:
    enabled = _enabled_providers(profile)
    step_ids = ["setup"]
    for provider_name in _OPTIONAL_PROVIDER_ORDER:
        if enabled.get(provider_name, False):
            step_ids.append(_PROVIDER_CHECK_STEP_IDS[provider_name])
    if enabled["beat_this"]:
        step_ids.append("beat_this.analyze")
    step_ids.append("baseline_mir.analyze")
    if enabled["songformer"]:
        step_ids.extend(["songformer.analyze_segments", "songformer.add_point_candidates"])
    step_ids.append("constraints.after_structure")
    if enabled["mert"]:
        step_ids.extend(["mert.score_candidates", "constraints.after_mert"])
    if enabled["demucs"]:
        step_ids.append("demucs.score_candidates")
    step_ids.extend(["constraints.after_demucs", "finalize_payload"])
    return step_ids


def _skip_progress_step(progress: _ProgressReporter, step_id: str, status: ProviderStatus) -> None:
    progress.completed(
        step_id,
        status="skipped",
        summary=f"{status.name} {status.status}",
        warnings=status.warnings,
        runtime_ms=0,
    )


def build_analysis_payload(args, progress: Optional[_ProgressReporter] = None) -> Dict[str, object]:
    progress = progress or _ProgressReporter(False)
    timer = _StageTimer()
    progress.plan(args.profile, _progress_plan_step_ids(args.profile))

    def _setup():
        source = Path(args.input).expanduser()
        if not source.exists():
            die(f"Input audio not found: {source}")
        ffmpeg = find_executable(args.ffmpeg, "ffmpeg") if args.ffmpeg else None
        model_dir = _model_dir(args.model_dir)
        return source, ffmpeg, model_dir

    progress.started("setup")
    try:
        (source, ffmpeg, model_dir), setup_runtime_ms = _run_timed_stage(timer, "setup", _setup)
    except Exception as exc:
        progress.failed("setup", f"{type(exc).__name__}: {exc}")
        raise
    progress.completed("setup", runtime_ms=setup_runtime_ms)
    enabled_provider_names = _enabled_optional_provider_names(args.profile)
    provider_statuses_by_name: Dict[str, ProviderStatus] = {}
    for provider_name in enabled_provider_names:
        step_id = _PROVIDER_CHECK_STEP_IDS[provider_name]
        progress.started(step_id)
        try:
            status, runtime_ms = _run_timed_stage(
                timer,
                step_id,
                lambda provider_name=provider_name: _check_provider(provider_name, model_dir),
            )
        except Exception as exc:
            progress.failed(step_id, f"{type(exc).__name__}: {exc}")
            raise
        status.runtime_ms = runtime_ms
        provider_statuses_by_name[provider_name] = status
        progress.completed(
            step_id,
            status=_check_progress_status(status),
            summary=_check_progress_summary(status),
            warnings=status.warnings,
            runtime_ms=runtime_ms,
        )

    beat_status = provider_statuses_by_name.get("beat_this")
    beat_result: Dict[str, object] = {
        "beats": [],
        "downbeats": [],
        "bpm": None,
        "confidence": 0.0,
        "warnings": [],
    }
    if beat_status is not None:
        beat_result["status"] = beat_status
    beat_evidence = None
    if beat_status is not None and beat_status.status == "ready":
        with (
            progress.stage("beat_this.analyze"),
            timer.stage("beat_this.analyze"),
        ):
            beat_result = beat_this.analyze(
                source,
                model_dir=model_dir,
                max_beats=args.max_beats,
            )
        beat_status = beat_result["status"]  # type: ignore[assignment]
        provider_statuses_by_name["beat_this"] = beat_status
        if beat_result.get("beats"):
            beat_evidence = {
                "provider": "beat_this",
                "beats": beat_result.get("beats", []),
                "downbeats": beat_result.get("downbeats", []),
                "bpm": beat_result.get("bpm"),
                "confidence": beat_result.get("confidence", 0.0),
            }
    elif beat_status is not None:
        _skip_progress_step(progress, "beat_this.analyze", beat_status)
    with progress.stage("baseline_mir.analyze"), timer.stage("baseline_mir.analyze"):
        baseline = baseline_mir.analyze(
            source,
            bins=args.bins,
            bpm=args.bpm,
            max_beats=args.max_beats,
            ffmpeg=ffmpeg,
            beat_evidence=beat_evidence,
        )
    candidates = baseline["candidates"]
    segments = baseline["segments"]
    songformer_status = provider_statuses_by_name.get("songformer")
    songformer_result: Dict[str, object] = {
        "segments": [],
        "warnings": [],
    }
    if songformer_status is not None:
        songformer_result["status"] = songformer_status
    if songformer_status is not None and songformer_status.status == "ready":
        with (
            progress.stage("songformer.analyze_segments"),
            timer.stage("songformer.analyze_segments"),
        ):
            songformer_result = songformer.analyze_segments(
                source,
                model_dir=model_dir,
            )
        songformer_status = songformer_result["status"]  # type: ignore[assignment]
        provider_statuses_by_name["songformer"] = songformer_status
        songformer_segments = songformer_result.get("segments") or []
        with (
            progress.stage("songformer.add_point_candidates"),
            timer.stage("songformer.add_point_candidates"),
        ):
            if songformer_segments:
                segments = songformer_segments  # type: ignore[assignment]
                candidates = songformer.add_structure_point_candidates(
                    candidates,  # type: ignore[arg-type]
                    segments,  # type: ignore[arg-type]
                    grid=baseline["grid"],  # type: ignore[arg-type]
                    duration=float(baseline["duration_sec"]),
                )
    elif songformer_status is not None:
        _skip_progress_step(progress, "songformer.analyze_segments", songformer_status)
        _skip_progress_step(progress, "songformer.add_point_candidates", songformer_status)
    with progress.stage("constraints.after_structure"), timer.stage("constraints.after_structure"):
        candidates = _apply_timing_constraints(
            candidates,  # type: ignore[arg-type]
            baseline["grid"],  # type: ignore[arg-type]
            float(baseline["duration_sec"]),
            segments=segments,  # type: ignore[arg-type]
            td_limit=8,
        )
    mert_status = provider_statuses_by_name.get("mert")
    mert_result: Dict[str, object] = {
        "candidates": candidates,
        "warnings": [],
    }
    if mert_status is not None:
        mert_result["status"] = mert_status
    if mert_status is not None and mert_status.status == "ready":
        with (
            progress.stage("mert.score_candidates"),
            timer.stage("mert.score_candidates"),
        ):
            mert_result = mert.score_loop_candidates(
                source,
                candidates,  # type: ignore[arg-type]
                model_dir=model_dir,
                ffmpeg=ffmpeg,
            )
        mert_status = mert_result["status"]  # type: ignore[assignment]
        provider_statuses_by_name["mert"] = mert_status
        candidates = mert_result["candidates"]
        with progress.stage("constraints.after_mert"), timer.stage("constraints.after_mert"):
            candidates = _apply_timing_constraints(
                candidates,  # type: ignore[arg-type]
                baseline["grid"],  # type: ignore[arg-type]
                float(baseline["duration_sec"]),
                segments=segments,  # type: ignore[arg-type]
                td_limit=8,
            )
    elif mert_status is not None:
        _skip_progress_step(progress, "mert.score_candidates", mert_status)
        _skip_progress_step(progress, "constraints.after_mert", mert_status)
    demucs_status = provider_statuses_by_name.get("demucs")
    demucs_result: Dict[str, object] = {
        "candidates": candidates,
        "warnings": [],
    }
    if demucs_status is not None:
        demucs_result["status"] = demucs_status
    if demucs_status is not None and demucs_status.status == "ready":
        with (
            progress.stage("demucs.score_candidates"),
            timer.stage("demucs.score_candidates"),
        ):
            demucs_result = demucs.score_candidates(
                source,
                candidates,  # type: ignore[arg-type]
                model_dir=model_dir,
                ffmpeg=ffmpeg,
            )
        demucs_status = demucs_result["status"]  # type: ignore[assignment]
        provider_statuses_by_name["demucs"] = demucs_status
        candidates = demucs_result["candidates"]
    elif demucs_status is not None:
        _skip_progress_step(progress, "demucs.score_candidates", demucs_status)
    with progress.stage("constraints.after_demucs"), timer.stage("constraints.after_demucs"):
        candidates = _apply_timing_constraints(
            candidates,  # type: ignore[arg-type]
            baseline["grid"],  # type: ignore[arg-type]
            float(baseline["duration_sec"]),
            segments=segments,  # type: ignore[arg-type]
            td_limit=8,
        )
    with progress.stage("finalize_payload"), timer.stage("finalize_payload"):
        statuses = [
            baseline["status"],
            *[
                provider_statuses_by_name[name]
                for name in _OPTIONAL_PROVIDER_ORDER
                if name in provider_statuses_by_name
            ],
        ]
        provider_caches: Dict[str, Dict[str, object]] = {
            "baseline_mir": {
                "version": "numpy-mir-v1",
                "cache": None,
                "grid_provider": baseline["grid"].get("provider"),
            }
        }
        if beat_status is not None:
            provider_caches["beat_this"] = {
                "version": beat_status.version,
                "cache": str((model_dir / "beat_this").resolve()),
                "status": beat_status.status,
                "runtime_ms": beat_status.runtime_ms,
            }
        if mert_status is not None:
            provider_caches["mert"] = {
                "version": mert_status.version,
                "cache": str((model_dir / "mert" / "repo").resolve()),
                "status": mert_status.status,
                "runtime_ms": mert_status.runtime_ms,
            }
        if songformer_status is not None:
            provider_caches["songformer"] = {
                "version": songformer_status.version,
                "cache": str((model_dir / "songformer" / "repo").resolve()),
                "status": songformer_status.status,
                "runtime_ms": songformer_status.runtime_ms,
            }
        if demucs_status is not None:
            provider_caches["demucs"] = {
                "version": demucs_status.version,
                "cache": str((model_dir / "demucs").resolve()),
                "status": demucs_status.status,
                "runtime_ms": demucs_status.runtime_ms,
            }
        cache_manifest = build_cache_manifest(
            source,
            float(baseline["duration_sec"]),
            int(baseline["sample_rate"]),
            args.profile,
            provider_caches=provider_caches,
        )
        warnings = [
            *baseline.get("warnings", []),
            *beat_result.get("warnings", []),
            *songformer_result.get("warnings", []),
            *mert_result.get("warnings", []),
            *demucs_result.get("warnings", []),
            *_status_warnings(statuses),
        ]
        title = source.stem
        duration = float(baseline["duration_sec"])
        sample_rate = int(baseline["sample_rate"])
        channels = int(baseline["channels"])
        samples = int(baseline["samples"])
        bpm = float(baseline["bpm"])
    timings = timer.snapshot()
    provider_timings: Dict[str, object] = {}
    provider_runtime: Dict[str, object] = {}
    for provider_name, provider_result in (
        ("beat_this", beat_result),
        ("songformer", songformer_result),
        ("mert", mert_result),
        ("demucs", demucs_result),
    ):
        detail = provider_result.get("timings")
        if isinstance(detail, dict):
            provider_timings[provider_name] = detail
        runtime = provider_result.get("runtime")
        if isinstance(runtime, dict):
            provider_runtime[provider_name] = runtime
    return {
        "schema_version": SCHEMA_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": str(source.resolve()),
        "title": title,
        "duration_sec": duration,
        "sample_rate": sample_rate,
        "channels": channels,
        "samples": samples,
        "decoder": baseline["decoder"],
        "peak_dbfs": baseline["peak_dbfs"],
        "rms_dbfs": baseline["rms_dbfs"],
        "bpm": bpm,
        "ai_note": (
            "Beat This grid, SongFormer structure labels, MERT scoring, and Demucs stem evidence are active."
            if beat_evidence
            and _ready(provider_statuses_by_name, "songformer")
            and _ready(provider_statuses_by_name, "mert")
            and _ready(provider_statuses_by_name, "demucs")
            else (
                "Beat This grid, SongFormer structure labels, and MERT point/loop scoring are active."
                if beat_evidence
                and _ready(provider_statuses_by_name, "songformer")
                and _ready(provider_statuses_by_name, "mert")
                else (
                    "Beat This grid and MERT point/loop scoring are active; candidates are ranked with local embedding evidence."
                    if beat_evidence and _ready(provider_statuses_by_name, "mert")
                    else (
                        "SongFormer structure labels and MERT point/loop scoring are active over baseline candidates."
                        if _ready(provider_statuses_by_name, "songformer")
                        and _ready(provider_statuses_by_name, "mert")
                        else (
                            "Beat This beat/downbeat grid is active; candidates are ranked with local-base MIR evidence."
                            if beat_evidence
                            else (
                                "MERT point/loop scoring is active over baseline MIR candidates."
                                if _ready(provider_statuses_by_name, "mert")
                                else "Current AI contract is active. Candidates currently degrade to baseline evidence when deep providers are missing."
                            )
                        )
                    )
                )
            )
        ),
        "analysis": {
            "profile": args.profile,
            "providers": _provider_names(statuses),
            "provider_statuses": [status.to_json() for status in statuses],
            "duration_sec": duration,
            "source_sample_rate": sample_rate,
            "write_sample_rate": WRITE_SAMPLE_RATE,
            "bpm": bpm,
            "bpm_confidence": baseline["bpm_confidence"],
            "decoder": baseline["decoder"],
            "model_dir": str(model_dir.resolve()),
            "cache_manifest": cache_manifest,
            "timings": timings,
            "provider_timings": provider_timings,
            "provider_runtime": provider_runtime,
        },
        "grid": baseline["grid"],
        "beats": baseline["grid"]["beats"],
        "segments": segments,
        "candidates": candidates,
        "markers": baseline["markers"],
        "waveform": baseline["waveform"],
        "warnings": warnings,
    }


def _apply_timing_constraints(
    candidates: Dict[str, List[Dict[str, object]]],
    grid: Dict[str, object],
    duration: float,
    *,
    segments: Optional[Iterable[Dict[str, object]]] = None,
    td_limit: int = 8,
) -> Dict[str, List[Dict[str, object]]]:
    constrained = {key: list(value) for key, value in candidates.items()}
    if duration <= 0:
        return constrained

    segment_list = list(segments or [])
    td_cap = songformer.trackdrop_intro_cap(segment_list, duration)
    td_items = constrained.get("td", [])
    if td_cap is not None:
        td_items = [item for item in td_items if float(item.get("t", 0.0)) <= td_cap]
    td_latest = duration if duration < 30.0 else duration * 0.58
    early_td = [item for item in td_items if float(item.get("t", 0.0)) <= td_latest]
    if early_td:
        adjusted_td: List[Dict[str, object]] = []
        for item in early_td:
            adjusted = dict(item)
            time = float(adjusted.get("t", 0.0))
            bonus = _track_start_usability_bonus(time, duration)
            if bonus:
                evidence = dict(adjusted.get("evidence") or {})
                previous_bonus = float(evidence.get("track_start_usability_bonus", 0.0) or 0.0)
                delta = bonus - previous_bonus
                if delta:
                    adjusted["score"] = round(
                        max(0.0, min(0.96, float(adjusted.get("score", 0.0)) + delta)), 3
                    )
                evidence["track_start_usability_bonus"] = round(bonus, 3)
                if "track_start_policy" in evidence:
                    evidence["track_start_bonus_policy"] = "prefer recognizable intro/base kickoff"
                else:
                    evidence["track_start_policy"] = "prefer recognizable intro/base kickoff"
                adjusted["evidence"] = evidence
            adjusted_td.append(adjusted)
        constrained["td"] = sort_point_candidates(adjusted_td, limit=td_limit)
    elif td_cap is not None:
        constrained["td"] = sort_point_candidates(td_items, limit=td_limit)

    current_td = constrained.get("td", [])
    top_td = current_td[0] if current_td else {}
    td_time = float(top_td.get("t", 0.0)) if top_td else 0.0
    min_loop_start = td_time + max(_bar_step(grid), 1.0)
    tl_items = constrained.get("tl", [])
    if tl_items:
        tl_items = _apply_track_loop_policy(tl_items, segment_list, duration)
    anchor_policy = _trackdrop_anchor_policy(top_td)
    if anchor_policy == "hard_high_confidence":
        valid_tl = [
            _with_track_loop_anchor_evidence(
                item, td_time, min_loop_start, anchor_policy, penalty=0.0
            )
            for item in tl_items
            if float(item.get("start", 0.0)) > min_loop_start
            and float(item.get("end", 0.0)) > float(item.get("start", 0.0))
        ]
        if valid_tl:
            constrained["tl"] = sort_track_loop_candidates(valid_tl)
    elif tl_items:
        adjusted_tl: List[Dict[str, object]] = []
        for item in tl_items:
            start = float(item.get("start", 0.0))
            penalty = 0.08 if top_td and start <= min_loop_start else 0.0
            adjusted_tl.append(
                _with_track_loop_anchor_evidence(
                    item,
                    td_time,
                    min_loop_start,
                    anchor_policy,
                    penalty=penalty,
                )
            )
        constrained["tl"] = sort_track_loop_candidates(adjusted_tl)

    pd_items = constrained.get("pd", [])
    pl_items = constrained.get("pl", [])
    if pl_items:
        constrained["pd"], constrained["pl"] = _apply_postdrop_post_loop_constraints(
            pd_items,
            pl_items,
            segment_list,
            duration,
            pd_limit=td_limit,
        )

    return constrained


def _apply_track_loop_policy(
    items: List[Dict[str, object]],
    segments: List[Dict[str, object]],
    duration: float,
) -> List[Dict[str, object]]:
    adjusted: List[Dict[str, object]] = []
    for item in items:
        start = float(item.get("start", 0.0))
        end = float(item.get("end", start))
        bars = int(float(item.get("bars", 0.0)))
        start_label = _segment_label_at(segments, start)
        end_label = _segment_label_at(segments, max(start, end - 0.10))
        compatibility = _track_loop_label_compatibility(start_label, end_label)
        bonus = compatibility * 0.12
        penalty = 0.0
        if segments and compatibility < 0.45:
            penalty += 0.16
        if (
            _canonical_section_label(end_label) in {"bridge", "outro", "silence"}
            and compatibility < 0.8
        ):
            penalty += 0.10
        if _canonical_section_label(start_label) in {"intro", "silence"} and compatibility < 0.8:
            penalty += 0.08
        if bars > 48 and compatibility < 0.7:
            penalty += 0.06
        if duration > 0 and (end - start) > duration * 0.62 and compatibility < 0.8:
            penalty += 0.04

        next_item = dict(item)
        base_score = float(next_item.get("score", 0.0))
        next_item["score"] = round(max(0.0, min(0.96, base_score * 0.82 + bonus - penalty)), 3)
        evidence = dict(next_item.get("evidence") or {})
        evidence["track_loop_policy"] = "prefer compatible section seam"
        evidence["track_loop_start_label"] = start_label
        evidence["track_loop_end_label"] = end_label
        evidence["track_loop_label_compatibility"] = round(compatibility, 3)
        evidence["track_loop_policy_bonus"] = round(bonus, 3)
        evidence["track_loop_policy_penalty"] = round(penalty, 3)
        next_item["evidence"] = evidence
        adjusted.append(next_item)
    return sort_track_loop_candidates(adjusted, limit=16)


def _segment_label_at(segments: List[Dict[str, object]], time: float) -> str:
    for segment in segments:
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        if start <= time < end:
            return str(segment.get("label") or "")
    return ""


def _track_loop_label_compatibility(start_label: str, end_label: str) -> float:
    start = _canonical_section_label(start_label)
    end = _canonical_section_label(end_label)
    if not start or not end:
        return 0.5
    if start == end:
        return 1.0
    chorus_like = {"chorus", "hook", "drop", "refrain"}
    verse_like = {"intro", "verse"}
    if start in chorus_like and end in chorus_like:
        return 0.82
    if start in verse_like and end in verse_like:
        return 0.62
    if {start, end} <= {"prechorus", "chorus"}:
        return 0.42
    if start in {"bridge", "outro", "silence"} or end in {"bridge", "outro", "silence"}:
        return 0.0
    return 0.25


def _canonical_section_label(label: str) -> str:
    normalized = str(label or "").lower().replace("-", "").replace("_", "").replace(" ", "")
    if "prechorus" in normalized:
        return "prechorus"
    if any(token in normalized for token in ("chorus", "hook", "refrain")):
        return "chorus"
    if "drop" in normalized:
        return "drop"
    if "verse" in normalized:
        return "verse"
    if "intro" in normalized:
        return "intro"
    if "bridge" in normalized:
        return "bridge"
    if "outro" in normalized:
        return "outro"
    if "silence" in normalized:
        return "silence"
    return normalized


def _bar_step(grid: Dict[str, object]) -> float:
    bars = [
        float(item.get("start", 0.0))
        for item in grid.get("bars", [])
        if isinstance(item, dict) and "start" in item
    ]
    diffs = [
        bars[index] - bars[index - 1]
        for index in range(1, len(bars))
        if bars[index] > bars[index - 1]
    ]
    if diffs:
        return sorted(diffs)[len(diffs) // 2]
    beat_step = grid.get("beat_step")
    return float(beat_step) * 4.0 if beat_step else 2.0


def _apply_postdrop_post_loop_constraints(
    pd_items: List[Dict[str, object]],
    pl_items: List[Dict[str, object]],
    segments: List[Dict[str, object]],
    duration: float,
    *,
    pd_limit: int,
) -> tuple[List[Dict[str, object]], List[Dict[str, object]]]:
    sorted_pd = sort_point_candidates(pd_items, limit=pd_limit) if pd_items else []
    post_drop_time = float(sorted_pd[0].get("t", 0.0)) if sorted_pd else None
    return sorted_pd, _apply_post_loop_policy(
        pl_items,
        segments,
        duration,
        post_drop_time=post_drop_time,
    )


def _post_loop_meets_hard_constraints(
    item: Dict[str, object],
    *,
    post_drop_time: Optional[float],
) -> bool:
    start = float(item.get("start", 0.0))
    end = float(item.get("end", start))
    if end <= start:
        return False
    if end - start + 1e-6 < _MIN_POST_LOOP_SECONDS:
        return False
    if (
        post_drop_time is not None
        and end - post_drop_time + 1e-6 < _MIN_POST_LOOP_END_AFTER_POSTDROP_SECONDS
    ):
        return False
    return True


def _apply_post_loop_policy(
    items: List[Dict[str, object]],
    segments: List[Dict[str, object]],
    duration: float,
    *,
    post_drop_time: Optional[float],
) -> List[Dict[str, object]]:
    chorus_ranges = _chorus_ranges(segments)
    adjusted: List[Dict[str, object]] = []
    for item in items:
        if not _post_loop_meets_hard_constraints(item, post_drop_time=post_drop_time):
            continue
        start = float(item.get("start", 0.0))
        end = float(item.get("end", start))
        loop_duration = max(0.0, end - start)
        bars = int(float(item.get("bars", 0.0)))
        chorus_overlap = _max_overlap_ratio(start, end, chorus_ranges)
        length_prior = _post_loop_length_prior(bars)
        postdrop_anchor = _post_loop_postdrop_anchor_fit(start, end, post_drop_time)
        penalty = 0.0
        bonus = length_prior * 0.08 + postdrop_anchor * 0.14
        if chorus_ranges:
            if chorus_overlap >= 0.45:
                bonus += chorus_overlap * 0.16
            else:
                penalty += 0.18
        if post_drop_time is not None and postdrop_anchor < 0.35:
            penalty += 0.12
        if bars > 16:
            penalty += min(0.22, (bars - 16) / 48.0 * 0.22)
        if duration > 0 and loop_duration > duration * 0.22:
            penalty += 0.08
        next_item = dict(item)
        base_score = float(next_item.get("score", 0.0))
        next_item["score"] = round(max(0.0, min(0.96, base_score * 0.76 + bonus - penalty)), 3)
        evidence = dict(next_item.get("evidence") or {})
        evidence["post_loop_policy"] = "prefer short chorus loop"
        evidence["post_loop_chorus_overlap"] = round(chorus_overlap, 3)
        evidence["post_loop_length_prior"] = round(length_prior, 3)
        evidence["post_loop_postdrop_anchor"] = round(postdrop_anchor, 3)
        evidence["post_loop_policy_bonus"] = round(bonus, 3)
        evidence["post_loop_policy_penalty"] = round(penalty, 3)
        evidence["post_loop_min_duration_sec"] = _MIN_POST_LOOP_SECONDS
        if post_drop_time is not None:
            evidence["postdrop_anchor_sec"] = round(post_drop_time, 3)
            evidence["post_loop_min_end_after_postdrop_sec"] = (
                _MIN_POST_LOOP_END_AFTER_POSTDROP_SECONDS
            )
            evidence["post_loop_min_end_sec"] = round(
                post_drop_time + _MIN_POST_LOOP_END_AFTER_POSTDROP_SECONDS,
                3,
            )
        next_item["evidence"] = evidence
        adjusted.append(next_item)
    if chorus_ranges:
        chorus_focused = [
            item
            for item in adjusted
            if float(dict(item.get("evidence") or {}).get("post_loop_chorus_overlap", 0.0)) >= 0.45
        ]
        if chorus_focused:
            adjusted = chorus_focused
    return sort_post_loop_candidates(adjusted, limit=8)


def _post_loop_postdrop_anchor_fit(
    start: float,
    end: float,
    post_drop_time: Optional[float],
) -> float:
    if post_drop_time is None:
        return 0.0
    if start <= post_drop_time <= end:
        return 1.0
    if post_drop_time < start:
        return max(0.0, 1.0 - (start - post_drop_time) / 12.0) * 0.72
    return max(0.0, 1.0 - (post_drop_time - end) / 12.0) * 0.35


def _chorus_ranges(segments: Iterable[Dict[str, object]]) -> List[tuple[float, float]]:
    ranges: List[tuple[float, float]] = []
    for segment in segments:
        label = str(segment.get("label") or "").lower().replace("-", "").replace("_", "")
        if not any(token in label for token in ("chorus", "refrain", "hook", "drop")):
            continue
        start = float(segment.get("start", 0.0))
        end = float(segment.get("end", start))
        if end > start:
            ranges.append((start, end))
    return ranges


def _max_overlap_ratio(start: float, end: float, ranges: Iterable[tuple[float, float]]) -> float:
    loop_duration = max(0.0, end - start)
    if loop_duration <= 0:
        return 0.0
    best = 0.0
    for range_start, range_end in ranges:
        overlap = max(0.0, min(end, range_end) - max(start, range_start))
        best = max(best, overlap / loop_duration)
    return best


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


def _track_start_usability_bonus(time: float, duration: float) -> float:
    if duration <= 0 or time < 0.0:
        return 0.0
    readiness = baseline_mir.track_start_opening_readiness(time, duration)
    ratio = time / duration
    if ratio <= 0.09:
        return 0.18 * readiness
    if ratio <= 0.16:
        return 0.18 - (ratio - 0.09) / 0.07 * 0.10
    if ratio <= 0.25:
        return -((ratio - 0.16) / 0.09 * 0.08)
    return -0.12


def _trackdrop_anchor_policy(item: Dict[str, object]) -> str:
    if not item:
        return "no_anchor"
    score = float(item.get("score", 0.0))
    evidence = dict(item.get("evidence") or {})
    if evidence.get("track_start_role") == "recognizable_intro_base_kickoff" and score >= 0.55:
        return "hard_high_confidence"
    if score >= 0.72:
        return "hard_high_confidence"
    return "soft_low_confidence"


def _with_track_loop_anchor_evidence(
    item: Dict[str, object],
    td_time: float,
    min_loop_start: float,
    anchor_policy: str,
    *,
    penalty: float,
) -> Dict[str, object]:
    adjusted = dict(item)
    if penalty:
        adjusted["score"] = round(max(0.0, float(adjusted.get("score", 0.0)) - penalty), 3)
    evidence = dict(adjusted.get("evidence") or {})
    evidence["trackdrop_anchor_policy"] = anchor_policy
    if anchor_policy != "no_anchor":
        evidence["trackdrop_anchor_sec"] = round(td_time, 3)
        evidence["track_loop_min_start_sec"] = round(min_loop_start, 3)
        evidence["track_loop_anchor_penalty"] = round(penalty, 3)
    adjusted["evidence"] = evidence
    return adjusted


def cmd_analyze_audio(args) -> int:
    payload = build_analysis_payload(
        args,
        progress=_ProgressReporter(bool(getattr(args, "progress_jsonl", False))),
    )
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0
    print(f"Audio     : {payload['source']}")
    print(f"Profile   : {payload['analysis']['profile']}")
    print(f"Duration  : {float(payload['duration_sec']):.3f}s")
    print(f"SampleRate: {payload['sample_rate']} Hz -> {WRITE_SAMPLE_RATE} Hz markers")
    print("Provider status:")
    for status in payload["analysis"]["provider_statuses"]:
        print(f"  {status['name']:<12} {status['status']}")
    timings = dict(payload["analysis"].get("timings") or {})
    stages = list(timings.get("stages") or [])
    if stages:
        print("Timings:")
        print(f"  {'total':<28} {int(timings.get('total_ms', 0)):>7} ms")
        for item in stages:
            if not isinstance(item, dict):
                continue
            print(f"  {str(item.get('name', 'stage')):<28} {int(item.get('runtime_ms', 0)):>7} ms")
    print("Top candidates:")
    candidates = payload["candidates"]
    for group in ("td", "pd"):
        items = candidates.get(group, [])
        if items:
            print(f"  {group.upper():<2} {items[0]['t']:>8.3f}s  score={items[0]['score']}")
    for group in ("tl", "pl"):
        items = candidates.get(group, [])
        if items:
            print(
                f"  {group.upper():<2} {items[0]['start']:>8.3f}s -> "
                f"{items[0]['end']:.3f}s  score={items[0]['score']}"
            )
    return 0


def cmd_check_ai_tools(args) -> int:
    model_dir = _model_dir(args.model_dir)
    statuses = [baseline_mir.check(), *_deep_statuses(args.profile, model_dir)]
    payload = {
        "profile": args.profile,
        "model_dir": str(model_dir.resolve()),
        "runtime_network_required": False,
        "providers": [status.to_json() for status in statuses],
        "warnings": _status_warnings(statuses),
    }
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0
    print(f"AI profile : {args.profile}")
    print(f"Model Dir  : {model_dir.resolve()}")
    for item in payload["providers"]:
        print(f"  {item['name']:<12} {item['status']}")
    return 0


def cmd_prepare_ai_cache(args) -> int:
    model_dir = _model_dir(args.model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    providers = _provider_names([baseline_mir.check(), *_deep_statuses(args.profile, model_dir)])
    manifest = write_install_manifest(model_dir, args.profile, providers)
    warmed: List[Dict[str, object]] = []
    requested_warmups = args.warmup_provider or []
    for index, provider in enumerate(requested_warmups, start=1):
        if not args.json:
            print(
                f"AI Warmup [{index}/{len(requested_warmups)}] starting {provider}; "
                "download, cache verification, and model load may be quiet for a while.",
                flush=True,
            )
        if provider == "beat_this":
            warmed.append(beat_this.warmup(model_dir).to_json())
        if provider == "mert":
            warmed.append(mert.warmup(model_dir).to_json())
        if provider == "songformer":
            warmed.append(songformer.warmup(model_dir).to_json())
        if provider == "demucs":
            warmed.append(demucs.warmup(model_dir).to_json())
        if not args.json and warmed:
            latest = warmed[-1]
            runtime = latest.get("runtime_ms")
            runtime_text = f" in {runtime} ms" if isinstance(runtime, int) and runtime > 0 else ""
            print(
                f"AI Warmup [{index}/{len(requested_warmups)}] finished "
                f"{latest['name']}: {latest['status']}{runtime_text}",
                flush=True,
            )
    warmup_failures = [item for item in warmed if item.get("status") not in {"ready", "ok"}]
    payload = {
        "profile": args.profile,
        "model_dir": str(model_dir.resolve()),
        "manifest": str(manifest.resolve()),
        "status": "error" if warmup_failures else ("ready" if warmed else "scaffolded"),
        "warmed": warmed,
        "warmup_failed": bool(warmup_failures),
        "failed_providers": warmup_failures,
        "warnings": [
            "Python dependencies are managed by uv. This command only creates the local model cache layout and manifest."
        ],
    }
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 1 if warmup_failures else 0
    print(f"Created AI model manifest scaffold: {manifest.resolve()}")
    print(payload["warnings"][0])
    for item in warmed:
        print(f"  warmed {item['name']}: {item['status']}")
        if item.get("status") not in {"ready", "ok"}:
            for warning in item.get("warnings") or []:
                print(f"    {warning}")
    if warmup_failures:
        failed = ", ".join(f"{item['name']}={item['status']}" for item in warmup_failures)
        print(f"Model Warmup failed: {failed}")
        return 1
    return 0
