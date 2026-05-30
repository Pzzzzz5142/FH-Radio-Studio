from __future__ import annotations

import multiprocessing as mp
import os
import queue
import threading
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, as_completed, wait
from contextlib import contextmanager
from time import perf_counter
from typing import Any, Iterable, Iterator

from .ai_timepoints.providers.baseline_mir import estimate_timing
from .audio import (
    bpm_from_override,
    build_markers,
    load_timing_overrides,
    marker_seconds_from_override,
    timing_override_for,
)
from .baseline_order import is_baseline_derived_index_path, load_baseline_bank_order_names
from .common import *
from .external_tools import find_executable
from .fsb5 import bank_name_from_path, parse_fsb5, rewrite_fsb5_names, splice_fsb5_into_bank
from .game import (
    audio_dir_for,
    default_radio_info,
    find_child_by_attr,
    find_station,
    iter_track_samples,
    parse_xml,
    radio_info_files,
    resolve_game_dir,
    steam_game_version,
)
from .language import normalize_text_language, string_tables_dir_for
from .loudness import (
    DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU,
    LOUDNESS_ALGORITHM_VERSION,
    analyze_loudness_file,
    baseline_loudness_bank_count,
    build_custom_set_loudness_profile,
    ensure_baseline_loudness_envelope,
    loudness_worker_count,
    normalize_custom_loudness_offset_lu,
    prepare_loudness_matched_audio,
)
from .metadata import (
    cached_loudness_analysis_for_path,
    infer_metadata_cache_path_from_timing_manifest,
    upsert_track_metadata_cache_entry,
)
from .radio_xml import patch_package_xml_tree

PROGRESS_PREFIX = "FH_RADIO_STUDIO_PROGRESS "
_METADATA_CACHE_LOCK: Any = threading.Lock()
_RADIO_PROGRESS_QUEUE: Any = None
CORE_TIMING_MARKERS = (
    "TrackDrop",
    "PostDrop",
    "TrackLoopStart",
    "TrackLoopEnd",
    "PostRaceLoopStart",
    "PostRaceLoopEnd",
)


def _args_loudness_offset_lu(args: argparse.Namespace) -> float:
    return normalize_custom_loudness_offset_lu(
        getattr(args, "loudness_offset_lu", DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU)
    )


class _PackageProgressReporter:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled
        self._started: Dict[str, float] = {}
        self._lock = threading.RLock()

    def plan(self, steps: List[Dict[str, object]]) -> None:
        self.emit({"event": "plan", "steps": steps})

    @contextmanager
    def stage(self, step_id: str, *, summary: str = "") -> Iterator[None]:
        self.started(step_id)
        try:
            yield
        except Exception as exc:
            self.failed(step_id, f"{type(exc).__name__}: {exc}")
            raise
        else:
            self.completed(step_id, summary=summary)

    def started(self, step_id: str) -> None:
        with self._lock:
            self._started[step_id] = perf_counter()
            self.emit({"event": "step_started", "step_id": step_id})

    def completed(
        self,
        step_id: str,
        *,
        status: str = "done",
        summary: str = "",
        runtime_ms: Optional[int] = None,
    ) -> None:
        with self._lock:
            started = self._started.pop(step_id, None)
            if runtime_ms is None:
                runtime_ms = (
                    int(round((perf_counter() - started) * 1000)) if started is not None else 0
                )
            payload: Dict[str, object] = {
                "event": "step_completed",
                "step_id": step_id,
                "status": status,
                "runtime_ms": runtime_ms,
            }
            if summary:
                payload["summary"] = summary
            self.emit(payload)

    def failed(self, step_id: str, message: str) -> None:
        with self._lock:
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
        with self._lock:
            print(
                f"{PROGRESS_PREFIX}{json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}",
                file=sys.stderr,
                flush=True,
            )


class _QueuePackageProgressReporter(_PackageProgressReporter):
    def __init__(self, progress_queue: Any) -> None:
        super().__init__(True)
        self._progress_queue = progress_queue

    def emit(self, payload: Dict[str, object]) -> None:
        if not self.enabled:
            return
        with self._lock:
            self._progress_queue.put(payload)


def _init_radio_package_worker(progress_queue: Any) -> None:
    global _RADIO_PROGRESS_QUEUE
    _RADIO_PROGRESS_QUEUE = progress_queue


def _progress_step(
    step_id: str,
    label: str,
    detail: str,
    *,
    weight: int = 1,
    processes: Optional[int] = None,
    work_items: Optional[int] = None,
) -> Dict[str, object]:
    step: Dict[str, object] = {
        "id": step_id,
        "label": label,
        "detail": detail,
        "weight": weight,
    }
    if processes is not None and processes > 1:
        step["processes"] = processes
    if work_items is not None and work_items > 0:
        step["work_items"] = work_items
    return step


def _radio_progress_step_id(radio: int, step: str) -> str:
    return f"radio.{radio}.{step}"


def _radio_progress_prefix(radio: int, station_name: Optional[str]) -> str:
    name = (station_name or "").strip()
    return name or f"R{radio}"


def _radio_progress_steps(
    radio: int,
    music_count: int,
    *,
    skip_bank: bool,
    station_name: Optional[str] = None,
    worker_processes: int = 1,
    prepare_processes: int = 1,
) -> List[Dict[str, object]]:
    prefix = _radio_progress_prefix(radio, station_name)
    track_label = f"{music_count} 首" if music_count > 0 else "自建歌曲"
    return [
        _progress_step(
            _radio_progress_step_id(radio, "prepare_audio"),
            f"{prefix} 响度匹配与时间点",
            f"分析 {track_label}的响度，按当前歌单匹配后转为 48 kHz WAV，并写入已确认 marker。",
            weight=max(2, music_count * 2),
            processes=prepare_processes,
            work_items=music_count,
        ),
        _progress_step(
            _radio_progress_step_id(radio, "stage_bank"),
            f"{prefix} 铺满 bank 槽位",
            "按 FH6 原 bank 的 sample 顺序生成 fsbank staging WAV。",
            weight=2,
            processes=worker_processes,
        ),
        _progress_step(
            _radio_progress_step_id(radio, "rebuild_bank"),
            f"{prefix} 重建 FMOD bank",
            "运行 fsbankcl，修正 sample 名称，再拼回 .assets.bank。",
            weight=1 if skip_bank else 8,
            processes=worker_processes,
        ),
    ]


def _is_finite_loudness_number(value: object) -> bool:
    try:
        return bool(np.isfinite(float(value)))
    except (TypeError, ValueError):
        return False


def _baseline_loudness_cache_state(args: argparse.Namespace) -> str:
    raw = getattr(args, "baseline_manifest", None)
    if not raw:
        return "none"
    path = Path(str(raw)).expanduser()
    if not path.exists():
        return "none"
    try:
        manifest = load_manifest(path)
    except CliError:
        return "initializing"
    derived_values = manifest.get("derived_values")
    envelope = derived_values.get("loudness_envelope") if isinstance(derived_values, dict) else None
    if not isinstance(envelope, dict):
        return "initializing"
    if envelope.get("algorithm_version") != LOUDNESS_ALGORITHM_VERSION:
        return "initializing"
    required_numbers = (
        "reference_min_lufs",
        "reference_median_lufs",
        "reference_max_lufs",
        "safe_min_lufs",
        "safe_max_lufs",
        "true_peak_ceiling_dbtp",
        "max_positive_gain_db",
    )
    if any(not _is_finite_loudness_number(envelope.get(key)) for key in required_numbers):
        return "initializing"
    return "cached"


def _baseline_loudness_plan_parallelism(args: argparse.Namespace) -> Optional[int]:
    """初始化基线响度缓存时会并行解码原始 bank；预估进程数供进度 UI 体现。"""
    raw = getattr(args, "baseline_manifest", None)
    if not raw:
        return None
    path = Path(str(raw)).expanduser()
    if not path.exists():
        return None
    try:
        manifest = load_manifest(path)
    except CliError:
        return None
    bank_count = baseline_loudness_bank_count(manifest)
    if bank_count <= 1:
        return None
    return loudness_worker_count(getattr(args, "loudness_jobs", 0), bank_count)


def _baseline_loudness_progress_step(args: argparse.Namespace) -> Optional[Dict[str, object]]:
    state = _baseline_loudness_cache_state(args)
    if state == "none":
        return None
    initializing = state == "initializing"
    return _progress_step(
        "baseline_loudness",
        "原始电台响度缓存",
        (
            "首次初始化：需要解码原始 bank 建立响度范围缓存，会久一点。"
            if initializing
            else "读取已缓存的原始电台响度范围，用来限制自建歌单目标响度。"
        ),
        weight=10 if initializing else 1,
        processes=_baseline_loudness_plan_parallelism(args) if initializing else None,
    )


def _loudness_envelope_summary(envelope: Dict[str, object]) -> str:
    source = str(envelope.get("source", "unknown"))
    count = envelope.get("reference_track_count")
    if isinstance(count, int) and count > 0:
        return f"{source}, {count} 首参考"
    return source


def _ensure_package_loudness_envelope(
    args: argparse.Namespace,
    progress: _PackageProgressReporter,
) -> Dict[str, object]:
    state = _baseline_loudness_cache_state(args)
    if state == "none":
        return ensure_baseline_loudness_envelope(None)
    if state == "initializing":
        print("原始电台响度缓存：未命中，正在初始化；需要解码原始 bank，可能会久一点。")
    else:
        print("原始电台响度缓存：已命中，读取 cached envelope。")
    step_id = "baseline_loudness"
    progress.started(step_id)
    try:
        envelope = ensure_baseline_loudness_envelope(
            args.baseline_manifest,
            loudness_jobs=getattr(args, "loudness_jobs", 0),
        )
    except Exception as exc:
        progress.failed(step_id, f"{type(exc).__name__}: {exc}")
        raise
    progress.completed(step_id, summary=_loudness_envelope_summary(envelope))
    print(f"原始电台响度缓存：{_loudness_envelope_summary(envelope)}。")
    return envelope


def _metadata_cache_path_for_args(args: argparse.Namespace) -> Optional[Path]:
    raw = getattr(args, "metadata_cache", None)
    if raw:
        return Path(str(raw)).expanduser()
    return infer_metadata_cache_path_from_timing_manifest(getattr(args, "timing_manifest", None))


def _all_core_markers_overridden(override: Optional[Dict[str, object]]) -> bool:
    if not isinstance(override, dict):
        return False
    markers = override.get("markers_sec")
    if not isinstance(markers, dict):
        return False
    return all(
        marker_seconds_from_override(override, marker) is not None for marker in CORE_TIMING_MARKERS
    )


def _package_progress_plan(
    args: argparse.Namespace,
    radio_counts: List[Tuple[int, int, Optional[str]]],
    *,
    current_radio_passthrough: bool = False,
    song_loudness_count: int = 0,
) -> List[Dict[str, object]]:
    radio_worker_processes = (
        _radio_package_worker_count(len(radio_counts)) if not current_radio_passthrough else 1
    )
    song_loudness_processes = (
        _loudness_worker_count(args, song_loudness_count) if song_loudness_count > 0 else 1
    )
    steps = [
        _progress_step(
            "inspect_inputs",
            "读取构建输入",
            "解析 RadioInfo、播放列表草稿、目标 bank 和本地工具路径。",
            weight=1,
        )
    ]
    if current_radio_passthrough:
        steps.append(
            _progress_step(
                "copy_baseline_radio",
                "复制原始备份电台文件",
                "语言-only 包会保留原始备份 RadioInfo 和 bank 内容，只写入语言设置。",
                weight=3,
            )
        )
    else:
        baseline_step = _baseline_loudness_progress_step(args)
        if baseline_step is not None:
            steps.append(baseline_step)
        if song_loudness_count > 0:
            steps.append(
                _progress_step(
                    "song_loudness_cache",
                    "全局歌曲响度缓存",
                    "先不区分电台，并行测量本次准备包用到的自建歌曲响度；后续电台构建直接复用结果。",
                    weight=max(2, song_loudness_count * 2),
                    processes=song_loudness_processes,
                    work_items=song_loudness_count,
                )
            )
        for radio, music_count, station_name in radio_counts:
            prepare_processes = radio_worker_processes
            if song_loudness_count <= 0 and music_count > 1:
                prepare_processes = max(
                    prepare_processes,
                    _loudness_worker_count(args, music_count),
                )
            steps.extend(
                _radio_progress_steps(
                    radio,
                    music_count,
                    skip_bank=args.skip_bank,
                    station_name=station_name,
                    worker_processes=radio_worker_processes,
                    prepare_processes=prepare_processes,
                )
            )
    if args.source or args.target:
        steps.append(
            _progress_step(
                "package_language",
                "打包语言设置",
                "复制显示语言表到目标语音槽，并记录 UserPreferredLang。",
                weight=1,
            )
        )
    if not current_radio_passthrough:
        steps.append(
            _progress_step(
                "patch_xml",
                "写入 RadioInfo XML",
                "把新 sample、播放列表和 loop marker 写入所有语言 XML。",
                weight=2,
            )
        )
    steps.append(
        _progress_step(
            "complete_package",
            "补齐文件与 manifest",
            "复制 baseline 中未改动的受保护文件，计算 MD5，并写入包清单。",
            weight=2,
        )
    )
    return steps


def collect_package_deploy_files(package_dir: Path) -> List[Dict[str, object]]:
    package_root = package_root_dir(package_dir)
    package_audio = package_root / "media" / "audio"
    files: List[Dict[str, object]] = []
    if package_audio.is_dir():
        for src, rel in collect_package_files(package_audio, require_files=False):
            rel_text = str(rel).replace("\\", "/")
            files.append(
                {
                    "kind": "audio",
                    "source": src,
                    "relative_path": rel_text,
                    "install_relative_path": str(Path("media") / "audio" / rel).replace("\\", "/"),
                }
            )
    string_dir = package_root / "media" / "Stripped" / "StringTables"
    if string_dir.is_dir():
        for table in sorted(string_dir.glob("*.zip")):
            files.append(
                {
                    "kind": "string_table",
                    "source": table,
                    "relative_path": str(
                        Path("media") / "Stripped" / "StringTables" / table.name
                    ).replace("\\", "/"),
                    "install_relative_path": str(
                        Path("media") / "Stripped" / "StringTables" / table.name
                    ).replace("\\", "/"),
                }
            )
    if not files:
        die(f"No deployable package files found in {package_root}")
    return files


def _package_game_version_fields(game_dir: Path) -> Dict[str, object]:
    game_version = steam_game_version(game_dir)
    game_version_id = "unknown"
    if isinstance(game_version, dict):
        raw = game_version.get("version_id")
        if isinstance(raw, str) and raw.strip():
            game_version_id = sanitize_token(raw, "unknown").lower().replace("_", "-")
        else:
            build_id = game_version.get("build_id")
            if isinstance(build_id, str) and build_id.strip():
                game_version_id = f"steam-b{sanitize_token(build_id, 'unknown').lower()}"
    fields: Dict[str, object] = {
        "game_version": game_version,
        "game_version_id": game_version_id,
    }
    if game_version_id != "unknown":
        fields["supported_game_version_ids"] = [game_version_id]
    return fields


def package_file_fingerprints(package_dir: Path) -> List[Dict[str, object]]:
    return [
        {
            "kind": str(item.get("kind", "file")),
            "relative_path": str(item["relative_path"]),
            "install_relative_path": str(item["install_relative_path"]),
            "path": str(src.resolve()),
            "size": file_size(src),
            "md5": md5_file(src),
        }
        for item in collect_package_deploy_files(package_dir)
        for src in [Path(str(item["source"]))]
    ]


def _baseline_install_relative_path(item: Dict[str, object]) -> str:
    install_rel = str(item.get("install_relative_path") or "").replace("\\", "/").strip("/")
    if install_rel:
        return install_rel
    rel = str(item.get("relative_path") or "").replace("\\", "/").strip("/")
    if not rel:
        return ""
    if rel.startswith("media/") or rel == "UserPreferredLang":
        return rel
    if item.get("scope") == "string_table":
        return f"media/Stripped/StringTables/{rel}"
    return f"media/audio/{rel}"


def complete_package_from_baseline(
    package_root: Path,
    baseline_manifest: Optional[str],
) -> Optional[Dict[str, object]]:
    if not baseline_manifest:
        return None
    manifest_path = Path(baseline_manifest).expanduser()
    if not manifest_path.exists():
        die(f"Baseline manifest not found: {manifest_path}")

    from .baseline import resolve_baseline_backup_path

    manifest = load_manifest(manifest_path)
    copied = 0
    kept = 0
    files = 0
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict):
            continue
        install_rel = _baseline_install_relative_path(item)
        rel = str(item.get("relative_path") or "").replace("\\", "/").strip("/")
        if is_baseline_derived_index_path(install_rel) or is_baseline_derived_index_path(rel):
            continue
        if not install_rel or install_rel == "UserPreferredLang":
            continue
        files += 1
        dest = package_root / Path(*install_rel.split("/"))
        if dest.exists():
            kept += 1
            continue
        backup = resolve_baseline_backup_path(manifest_path, item)
        if not backup or not backup.exists():
            die(f"Baseline file missing for package completion: {install_rel}")
        expected_md5 = item.get("md5")
        if isinstance(expected_md5, str) and expected_md5:
            backup_md5 = md5_file(backup)
            if backup_md5 != expected_md5:
                die(
                    f"Baseline MD5 mismatch while completing package for {install_rel}: "
                    f"expected {expected_md5}, got {backup_md5}"
                )
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup, dest)
        copied += 1

    return {
        "baseline_manifest": str(manifest_path.resolve()),
        "baseline_files": files,
        "kept_package_files": kept,
        "copied_baseline_files": copied,
    }


def apply_baseline_completion(
    package_manifest: Dict[str, object],
    package_root: Path,
    args: argparse.Namespace,
) -> None:
    completion = complete_package_from_baseline(
        package_root,
        getattr(args, "baseline_manifest", None),
    )
    if completion is None:
        return
    package_manifest["baseline_completion"] = completion
    print(
        "Completed package from baseline: "
        f"{completion['kept_package_files']} generated, "
        f"{completion['copied_baseline_files']} copied unchanged, "
        f"{completion['baseline_files']} protected total"
    )


def run_streaming(cmd: List[str]) -> int:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip()
        if line:
            print(f"  {line}")
    proc.wait()
    return int(proc.returncode)


def run_fsbankcl(fsbankcl: str, stage_dir: Path, out_dir: Path, quality: int) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        fsbankcl,
        "-o",
        str(out_dir),
        "-format",
        "vorbis",
        "-quality",
        str(quality),
        "-recursive",
        str(stage_dir),
    ]
    print("Running fsbankcl:")
    print("  " + " ".join(f'"{part}"' if " " in part else part for part in cmd))
    returncode = run_streaming(cmd)
    if returncode != 0:
        die(f"fsbankcl exited with code {returncode}")
    expected = out_dir / f"{stage_dir.name}.fsb"
    if expected.exists():
        return expected
    hits = sorted(out_dir.rglob("*.fsb"))
    if not hits:
        die(f"fsbankcl produced no .fsb in {out_dir}")
    return hits[0]


def detect_pack_order(fsb_path: Path, expected_count: int) -> Optional[List[int]]:
    try:
        info = parse_fsb5(fsb_path)
    except CliError:
        return None
    if info.num_samples != expected_count:
        return None
    order: List[int] = []
    for sample in info.samples:
        if not re.fullmatch(r"\d+", sample.name or ""):
            return None
        order.append(int(sample.name) - 1)
    if sorted(order) != list(range(expected_count)):
        return None
    return order


def resolve_target_bank(audio_dir: Path, radio: int, explicit_bank: Optional[str]) -> Path:
    fmod_dir = audio_dir / "FMODBanks"
    if explicit_bank:
        name = explicit_bank
        if not name.endswith(".assets.bank"):
            name = f"{name}.assets.bank"
        path = fmod_dir / name
        if path.exists():
            return path
        die(f"Target bank not found: {path}")

    existing: List[Path] = []
    for suffix in ("CU1", "CU2", "Disk", "PDLC1", "PDLC2"):
        path = fmod_dir / f"R{radio}_Tracks_{suffix}.assets.bank"
        if not path.exists():
            continue
        existing.append(path)
        if bank_has_fsb(path):
            return path
    if existing:
        die(f"No parseable R{radio}_Tracks_*.assets.bank found in {fmod_dir}")
    die(f"No R{radio}_Tracks_*.assets.bank found in {fmod_dir}")


def bank_has_fsb(path: Path) -> bool:
    try:
        parse_fsb5(path)
    except CliError:
        return False
    return True


def resolve_target_bank_for_station(
    audio_dir: Path, station: ET.Element, radio: int, explicit_bank: Optional[str]
) -> Path:
    if explicit_bank:
        return resolve_target_bank(audio_dir, radio, explicit_bank)

    fmod_dir = audio_dir / "FMODBanks"
    banks = station.find("Banks")
    if banks is not None:
        candidates = [
            bank.get("Name", "")
            for bank in banks.findall("Bank")
            if bank.get("Name") and bank.get("Name", "").startswith(f"R{radio}_Tracks")
        ]
        for preferred in ("CU1", "CU2", "Disk", "PDLC1", "PDLC2"):
            for name in candidates:
                if name.endswith(f"_{preferred}"):
                    path = fmod_dir / f"{name}.assets.bank"
                    if path.exists() and bank_has_fsb(path):
                        return path
        for name in candidates:
            path = fmod_dir / f"{name}.assets.bank"
            if path.exists() and bank_has_fsb(path):
                return path

    return resolve_target_bank(audio_dir, radio, None)


def first_playlist_names(station: ET.Element) -> List[str]:
    playlist = find_child_by_attr(station, "PlayList", "Type", "FreeRoam")
    if playlist is None:
        return []
    return [
        (entry.get("Name") or "").strip()
        for entry in playlist.findall("Entry")
        if entry.get("Name")
    ]


def playlist_entry_names(station: ET.Element, playlist_type: str) -> List[str]:
    playlist = find_child_by_attr(station, "PlayList", "Type", playlist_type)
    if playlist is None:
        return []
    return [
        (entry.get("Name") or "").strip()
        for entry in playlist.findall("Entry")
        if entry.get("Name")
    ]


def playlist_entry_caps(station: ET.Element) -> Dict[str, int]:
    return {
        playlist_type: len(playlist_entry_names(station, playlist_type))
        for playlist_type in PLAYLIST_TYPES
    }


def playlist_entry_cap(
    station: ET.Element,
    playlist_type: str,
    fallback: int,
) -> int:
    cap = playlist_entry_caps(station).get(normalize_playlist_type(playlist_type), 0)
    return cap if cap > 0 else fallback


def playlist_entry_cap_for_types(
    station: ET.Element,
    playlist_types: Iterable[str],
    fallback: int,
) -> int:
    caps = [
        playlist_entry_cap(station, playlist_type, fallback) for playlist_type in playlist_types
    ]
    return min(caps) if caps else fallback


def playlist_entry_caps_for_types(
    station: ET.Element,
    playlist_types: Iterable[str],
    fallback: int,
) -> Dict[str, int]:
    result: Dict[str, int] = {}
    for raw_type in playlist_types:
        playlist_type = normalize_playlist_type(raw_type)
        result[playlist_type] = playlist_entry_cap(station, playlist_type, fallback)
    return result


def playlist_entry_caps_for_sources(
    station: ET.Element,
    sources: Iterable[Path],
    playlist_types_by_source: Optional[Dict[str, List[str]]],
    fallback: int,
) -> Dict[str, int]:
    active_types: List[str] = []
    if isinstance(playlist_types_by_source, dict):
        for source in sources:
            raw_types = playlist_types_by_source.get(source_key(Path(str(source))))
            values: Iterable[object]
            if isinstance(raw_types, list):
                values = raw_types
            elif isinstance(raw_types, str):
                values = [raw_types]
            else:
                values = PLAYLIST_TYPES
            for value in values:
                active_types.append(normalize_playlist_type(str(value)))
    if not active_types:
        active_types = list(PLAYLIST_TYPES)
    return playlist_entry_caps_for_types(station, active_types, fallback)


def aggregate_replaceable_slots(units: Iterable[Dict[str, object]]) -> Dict[str, int]:
    totals: Dict[str, int] = {}
    for unit in units:
        caps = unit.get("replaceable_slots")
        if not isinstance(caps, dict):
            continue
        for raw_type, value in caps.items():
            playlist_type = normalize_playlist_type(str(raw_type))
            slot_count = safe_int(str(value), 0)
            if slot_count > 0:
                totals[playlist_type] = totals.get(playlist_type, 0) + slot_count
    return totals


def collect_music_inputs(inputs: List[str]) -> List[Path]:
    suffixes = {".wav", ".flac", ".ogg", ".aiff", ".aif", ".mp3", ".m4a", ".aac"}
    results: List[Path] = []
    for raw in inputs:
        path = Path(raw).expanduser()
        if path.is_dir():
            results.extend(
                sorted(p for p in path.iterdir() if p.is_file() and p.suffix.lower() in suffixes)
            )
        elif path.is_file():
            results.append(path)
        else:
            die(f"Music input not found: {path}")
    if not results:
        die("No music files found")
    return results


def radio_code_for_station(radio: int, name: str) -> str:
    normalized = name.lower()
    if "horizon pulse" in normalized:
        return "HOR"
    if "bass arena" in normalized:
        return "BAS"
    if "block party" in normalized:
        return "BLK"
    if "eurobeat" in normalized:
        return "EUR"
    if "rocas" in normalized:
        return "ROC"
    if normalized == "xs" or "horizon xs" in normalized:
        return "XS"
    if "timeless" in normalized:
        return "TIM"
    if "mixmaster" in normalized:
        return "MIX"
    return f"R{radio}"


def normalize_playlist_type(value: object) -> str:
    return "Event" if str(value).strip().lower() == "event" else "FreeRoam"


def source_key(path: Path) -> str:
    return str(path.expanduser().resolve()).lower()


def _analyze_loudness_cache_miss_worker(
    path_text: str, ffmpeg: Optional[str]
) -> Tuple[str, Dict[str, object]]:
    path = Path(path_text)
    return path_text, analyze_loudness_file(path, ffmpeg=ffmpeg)


def _loudness_worker_count(args: argparse.Namespace, task_count: int) -> int:
    return loudness_worker_count(getattr(args, "loudness_jobs", 0), task_count)


def _radio_package_worker_count(radio_count: int) -> int:
    # 单个电台重建大致要吃 ~6 个逻辑核心（ffmpeg/fsbankcl + 内部响度并行），
    # 所以并行电台数按 逻辑核数 // 6 硬封顶，避免超额订阅拖慢整体。
    cpu_count = os.cpu_count() or 1
    return max(1, min(radio_count, cpu_count // 6))


def _drain_radio_progress_queue(progress_queue: Any, progress: _PackageProgressReporter) -> None:
    while True:
        try:
            payload = progress_queue.get_nowait()
        except queue.Empty:
            return
        if isinstance(payload, dict):
            progress.emit(payload)


def _measure_loudness_cache_misses(
    paths: List[Path],
    args: argparse.Namespace,
    ffmpeg: Optional[str],
    *,
    has_cache: bool,
    allow_parallel: bool = True,
) -> Dict[str, Dict[str, object]]:
    if not paths:
        return {}
    worker_count = _loudness_worker_count(args, len(paths)) if allow_parallel else 1
    label = "Loudness cache miss" if has_cache else "Loudness analysis"
    worker_label = f"{worker_count} process(es)" if allow_parallel else "current radio process"
    print(f"  {label}: measuring {len(paths)} song(s) with {worker_label}.")

    results: Dict[str, Dict[str, object]] = {}

    def record(path: Path, analysis: Dict[str, object]) -> None:
        if analysis.get("status") != "ok":
            die(f"Could not measure loudness for {path}: {analysis.get('error')}")
        results[source_key(path)] = analysis

    if worker_count <= 1:
        for path in paths:
            try:
                _, analysis = _analyze_loudness_cache_miss_worker(str(path), ffmpeg)
            except Exception as exc:
                die(f"Could not measure loudness for {path}: {type(exc).__name__}: {exc}")
            record(path, analysis)
        return results

    with ProcessPoolExecutor(max_workers=worker_count) as pool:
        futures = {
            pool.submit(_analyze_loudness_cache_miss_worker, str(path), ffmpeg): path
            for path in paths
        }
        for future in as_completed(futures):
            path = futures[future]
            try:
                _, analysis = future.result()
            except Exception as exc:
                die(f"Could not measure loudness for {path}: {type(exc).__name__}: {exc}")
            record(path, analysis)
    return results


def _unique_music_sources(groups: List[Dict[str, object]]) -> List[Path]:
    sources: List[Path] = []
    seen: set[str] = set()
    for group in groups:
        for raw_source in list(group["sources"]):
            source = Path(str(raw_source)).expanduser()
            key = source_key(source)
            if key in seen:
                continue
            seen.add(key)
            sources.append(source)
    return sources


def _read_loudness_cache_entry(
    metadata_cache: Optional[Path],
    music: Path,
) -> Optional[Dict[str, object]]:
    if metadata_cache is None:
        return None
    with _METADATA_CACHE_LOCK:
        return cached_loudness_analysis_for_path(
            metadata_cache,
            music,
            algorithm_version=LOUDNESS_ALGORITHM_VERSION,
        )


def _write_loudness_cache_entry(
    metadata_cache: Optional[Path],
    music: Path,
    analysis: Dict[str, object],
) -> None:
    if metadata_cache is None:
        return
    with _METADATA_CACHE_LOCK:
        upsert_track_metadata_cache_entry(
            metadata_cache,
            music,
            loudness_analysis=analysis,
        )


def _build_package_song_loudness_cache(
    sources: List[Path],
    args: argparse.Namespace,
    ffmpeg: Optional[str],
    progress: _PackageProgressReporter,
) -> Dict[str, Dict[str, object]]:
    if not sources:
        return {}

    metadata_cache = _metadata_cache_path_for_args(args)
    analyses: Dict[str, Dict[str, object]] = {}
    cache_misses: List[Path] = []
    cache_hits = 0

    step_id = "song_loudness_cache"
    progress.started(step_id)
    try:
        for music in sources:
            analysis = _read_loudness_cache_entry(metadata_cache, music)
            if analysis is None:
                cache_misses.append(music)
                continue
            if analysis.get("status") != "ok":
                die(f"Could not measure loudness for {music}: {analysis.get('error')}")
            cache_hits += 1
            analyses[source_key(music)] = analysis

        measured_analyses = _measure_loudness_cache_misses(
            cache_misses,
            args,
            ffmpeg,
            has_cache=metadata_cache is not None,
            allow_parallel=True,
        )
        for music in cache_misses:
            analysis = measured_analyses[source_key(music)]
            _write_loudness_cache_entry(metadata_cache, music, analysis)
            analyses[source_key(music)] = analysis
    except Exception as exc:
        progress.failed(step_id, f"{type(exc).__name__}: {exc}")
        raise
    else:
        progress.completed(
            step_id,
            summary=f"{cache_hits} hit(s), {len(cache_misses)} measured",
        )

    print(
        "  Global loudness cache: "
        f"{cache_hits} hit(s), {len(cache_misses)} measured for {len(sources)} unique song(s)."
    )
    return analyses


def target_names_for_bank(
    station: ET.Element,
    bank_info: object,
    target_bank: Path,
    baseline_manifest: Optional[str] = None,
) -> List[str]:
    target_names = [sample.name for sample in bank_info.samples]
    if all(target_names):
        return target_names

    baseline_names = load_baseline_bank_order_names(
        baseline_manifest,
        target_bank.name,
        bank_info.num_samples,
    )
    if baseline_names:
        print("Bank FSB name table is empty; using baseline bank-order calibration.")
        return baseline_names

    length_matched_names = target_names_by_sample_length(station, bank_info)
    if length_matched_names:
        print("Bank FSB name table is empty; using SampleLength-matched bank order.")
        return length_matched_names

    playlist_names = first_playlist_names(station)
    if len(playlist_names) == bank_info.num_samples:
        print("Bank FSB name table is empty; using FreeRoam playlist SoundName order.")
        return playlist_names

    sample_names = [
        sample.get("SoundName", "")
        for sample in iter_track_samples(station)
        if sample.get("SoundName")
    ]
    if len(sample_names) == bank_info.num_samples:
        print("Bank FSB name table is empty; using SampleList SoundName order.")
        return sample_names

    die(
        f"{target_bank.name} has unnamed FSB samples and XML names do not match "
        f"bank sample count ({len(playlist_names)} playlist / {len(sample_names)} samples / "
        f"{bank_info.num_samples} bank slots)."
    )


def target_names_by_sample_length(station: ET.Element, bank_info: object) -> Optional[List[str]]:
    candidates: List[Tuple[str, int, int, int]] = []
    for xml_index, sample in enumerate(iter_track_samples(station)):
        sound_name = (sample.get("SoundName") or "").strip()
        sample_length = safe_int(sample.get("SampleLength"), 0)
        sample_rate = safe_int(sample.get("SampleRate"), 0)
        if sound_name and sample_length > 0:
            candidates.append((sound_name, sample_length, sample_rate, xml_index))

    if not candidates or len(candidates) < bank_info.num_samples:
        return None

    used_xml_indexes: set[int] = set()
    matched_names: List[str] = []
    for bank_sample in bank_info.samples:
        matches: List[Tuple[int, str, int]] = []
        for sound_name, sample_length, sample_rate, xml_index in candidates:
            if xml_index in used_xml_indexes:
                continue
            if bank_sample.frequency and sample_rate and bank_sample.frequency != sample_rate:
                continue
            delta = abs(int(bank_sample.sample_count) - sample_length)
            tolerance = max(8, int(sample_length * 0.0005))
            if delta <= tolerance:
                matches.append((delta, sound_name, xml_index))

        matches.sort(key=lambda item: (item[0], item[2]))
        if len(matches) != 1:
            return None
        _delta, sound_name, xml_index = matches[0]
        used_xml_indexes.add(xml_index)
        matched_names.append(sound_name)

    return matched_names if len(matched_names) == bank_info.num_samples else None


def station_number_by_code(root: ET.Element) -> Dict[str, int]:
    stations = root.find("RadioStations")
    if stations is None:
        die("RadioStations element not found")
    out: Dict[str, int] = {}
    for station in stations.findall("RadioStation"):
        number = safe_int(station.get("Number"), 0)
        if number <= 0:
            continue
        code = radio_code_for_station(number, station.get("Name", ""))
        out[code] = number
        out[f"R{number}"] = number
    return out


def _resolve_playlist_plan_radio(
    raw_radio: str,
    code_to_number: Dict[str, int],
) -> Optional[int]:
    radio = code_to_number.get(raw_radio)
    if radio is None and raw_radio.startswith("R"):
        radio = safe_int(raw_radio[1:], 0) or None
    return radio


_STDIN_PLAN_CACHE: Optional[Dict[str, object]] = None
_STDIN_PLAN_LOADED = False


def load_plan_document(plan_path: Optional[str]) -> Optional[Dict[str, object]]:
    """Load a playlist plan document from a file path, or from stdin when
    ``plan_path == "-"``. build-package reads the plan twice (builtin targets +
    groups), so the stdin payload is read once and cached for the second read."""
    global _STDIN_PLAN_CACHE, _STDIN_PLAN_LOADED
    if not plan_path:
        return None
    if plan_path == "-":
        if not _STDIN_PLAN_LOADED:
            _STDIN_PLAN_LOADED = True
            raw = sys.stdin.buffer.read()
            if raw.strip():
                try:
                    decoded = json.loads(raw.decode("utf-8"))
                except json.JSONDecodeError as exc:
                    die(f"Playlist plan parse failed from stdin: {exc}")
                _STDIN_PLAN_CACHE = decoded if isinstance(decoded, dict) else None
        return _STDIN_PLAN_CACHE
    path = Path(plan_path).expanduser()
    if not path.exists():
        die(f"Playlist plan not found: {path}")
    data = load_manifest(path)
    return data if isinstance(data, dict) else None


def load_playlist_plan_builtin_targets(
    plan_path: Optional[str], root: ET.Element
) -> List[Dict[str, object]]:
    data = load_plan_document(plan_path)
    items = data.get("builtin_targets") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return []

    code_to_number = station_number_by_code(root)
    grouped: Dict[int, set[str]] = {}
    for item in items:
        if isinstance(item, str):
            parts = item.split("|")
            raw_radio = parts[0].strip().upper() if parts else ""
            raw_type = parts[1] if len(parts) > 1 else "FreeRoam"
        elif isinstance(item, dict):
            raw_radio = str(item.get("radio_code") or item.get("radioCode") or "").strip().upper()
            raw_type = item.get("playlist_type") or item.get("playlistType") or "FreeRoam"
        else:
            continue
        if not raw_radio:
            continue
        radio = _resolve_playlist_plan_radio(raw_radio, code_to_number)
        if radio is None:
            die(f"Playlist plan references unknown radio code: {raw_radio}")
        grouped.setdefault(radio, set()).add(normalize_playlist_type(raw_type))

    result: List[Dict[str, object]] = []
    for radio, playlist_types in sorted(grouped.items()):
        result.append(
            {
                "radio": radio,
                "playlist_types": sorted(
                    playlist_types,
                    key=lambda value: 0 if value == "FreeRoam" else 1,
                ),
            }
        )
    return result


def load_playlist_plan_groups(
    plan_path: Optional[str],
    root: ET.Element,
    *,
    skip_radios: Optional[set[int]] = None,
) -> List[Dict[str, object]]:
    data = load_plan_document(plan_path)
    items = data.get("assignments") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return []

    code_to_number = station_number_by_code(root)
    skip_radios = skip_radios or set()
    grouped: Dict[int, Dict[str, object]] = {}
    seen: set[Tuple[int, str, str]] = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        raw_source = str(item.get("source") or "").strip()
        raw_radio = str(item.get("radio_code") or item.get("radioCode") or "").strip().upper()
        if not raw_source or not raw_radio:
            continue
        radio = _resolve_playlist_plan_radio(raw_radio, code_to_number)
        if radio is None:
            die(f"Playlist plan references unknown radio code: {raw_radio}")
        if radio in skip_radios:
            continue
        source = Path(raw_source).expanduser()
        if not source.is_file():
            die(f"Playlist plan music source not found: {source}")
        playlist_type = normalize_playlist_type(
            item.get("playlist_type") or item.get("playlistType") or "FreeRoam"
        )
        key = source_key(source)
        dedupe_key = (radio, key, playlist_type)
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        group = grouped.setdefault(
            radio,
            {
                "radio": radio,
                "sources": [],
                "source_keys": set(),
                "playlist_types_by_source": {},
                "playlist_slots_by_source": {},
            },
        )
        if key not in group["source_keys"]:
            group["source_keys"].add(key)
            group["sources"].append(source)
        group["playlist_types_by_source"].setdefault(key, set()).add(playlist_type)
        slot = safe_int(str(item.get("slot") or ""), 0)
        if slot > 0:
            group["playlist_slots_by_source"].setdefault(key, {})[playlist_type] = slot

    result = sorted(grouped.values(), key=lambda item: int(item["radio"]))
    for group in result:
        group.pop("source_keys", None)
        group["playlist_types_by_source"] = {
            key: sorted(values, key=lambda value: 0 if value == "FreeRoam" else 1)
            for key, values in group["playlist_types_by_source"].items()
        }
        group["playlist_slots_by_source"] = {
            key: dict(values) for key, values in group["playlist_slots_by_source"].items()
        }
    return result


def _package_manifest_path_from_arg(package_arg: str) -> Path:
    path = Path(package_arg).expanduser()
    if path.is_file():
        return path
    package_root = package_root_dir(path)
    candidate = package_root / "fh_radio_studio_package_manifest.json"
    if candidate.exists():
        return candidate
    die(f"FH Radio Studio package manifest not found: {path}")


def _iter_package_assignment_units(manifest: Dict[str, object]) -> Iterable[Dict[str, object]]:
    radios = manifest.get("radios")
    if isinstance(radios, list):
        for radio in radios:
            if isinstance(radio, dict):
                yield radio


def _package_source_by_index(unit: Dict[str, object]) -> Dict[int, str]:
    result: Dict[int, str] = {}
    music = unit.get("music")
    if not isinstance(music, list):
        return result
    for index, item in enumerate(music):
        if not isinstance(item, dict):
            continue
        source = str(item.get("source") or "").strip()
        if source:
            result[index] = source
    return result


def _optional_int(value: object, default: int) -> int:
    if value is None:
        return default
    return safe_int(str(value), default)


def load_playlist_groups_from_package(
    package_arg: Optional[str], root: ET.Element
) -> List[Dict[str, object]]:
    if not package_arg:
        return []
    manifest_path = _package_manifest_path_from_arg(package_arg)
    manifest = load_manifest(manifest_path)
    code_to_number = station_number_by_code(root)
    grouped: Dict[int, Dict[str, object]] = {}
    seen: set[Tuple[int, str, str]] = set()

    for unit in _iter_package_assignment_units(manifest):
        unit_radio = safe_int(str(unit.get("radio") or ""), 0) or None
        unit_code = str(unit.get("radio_code") or "").strip().upper()
        source_by_index = _package_source_by_index(unit)
        assignments = unit.get("assignments")
        if not isinstance(assignments, list):
            continue
        for assignment in assignments:
            if not isinstance(assignment, dict):
                continue
            if assignment.get("playlist_entry") is False:
                continue
            raw_radio = (
                str(assignment.get("radio_code") or assignment.get("radioCode") or unit_code or "")
                .strip()
                .upper()
            )
            radio = code_to_number.get(raw_radio) if raw_radio else unit_radio
            if radio is None and raw_radio.startswith("R"):
                radio = safe_int(raw_radio[1:], 0) or None
            if radio is None:
                die(f"Package assignment references unknown radio code: {raw_radio or '<missing>'}")

            source = str(assignment.get("source") or "").strip()
            if not source:
                source_index = _optional_int(assignment.get("source_index"), -1)
                source = source_by_index.get(source_index, "")
            if not source:
                continue
            source_path = Path(source).expanduser()
            if not source_path.is_file():
                die(f"Package assignment music source not found: {source_path}")

            raw_types = assignment.get("playlist_types")
            playlist_types = (
                raw_types
                if isinstance(raw_types, list)
                else [assignment.get("playlist_type") or "FreeRoam"]
            )
            for raw_type in playlist_types:
                playlist_type = normalize_playlist_type(raw_type or "FreeRoam")
                key = source_key(source_path)
                dedupe_key = (radio, key, playlist_type)
                if dedupe_key in seen:
                    continue
                seen.add(dedupe_key)
                group = grouped.setdefault(
                    radio,
                    {
                        "radio": radio,
                        "sources": [],
                        "source_keys": set(),
                        "playlist_types_by_source": {},
                        "playlist_slots_by_source": {},
                    },
                )
                if key not in group["source_keys"]:
                    group["source_keys"].add(key)
                    group["sources"].append(source_path)
                group["playlist_types_by_source"].setdefault(key, set()).add(playlist_type)
                slot = _optional_int(assignment.get("slot"), 0)
                if slot <= 0:
                    slot = _optional_int(assignment.get("slot_index"), -1) + 1
                if slot > 0:
                    group["playlist_slots_by_source"].setdefault(key, {})[playlist_type] = slot

    result = sorted(grouped.values(), key=lambda item: int(item["radio"]))
    for group in result:
        group.pop("source_keys", None)
        group["playlist_types_by_source"] = {
            key: sorted(values, key=lambda value: 0 if value == "FreeRoam" else 1)
            for key, values in group["playlist_types_by_source"].items()
        }
        group["playlist_slots_by_source"] = {
            key: dict(values) for key, values in group["playlist_slots_by_source"].items()
        }
    return result


def prepare_music_tracks(
    music_files: List[Path],
    args: argparse.Namespace,
    prepared_dir: Path,
    timing_overrides: Dict[str, object],
    ffmpeg: Optional[str],
    *,
    radio: Optional[int] = None,
    loudness_envelope: Optional[Dict[str, object]] = None,
    parallel_loudness: bool = True,
    precomputed_loudness_by_source: Optional[Dict[str, Dict[str, object]]] = None,
) -> List[Dict[str, object]]:
    prepared_dir.mkdir(parents=True, exist_ok=True)
    envelope = loudness_envelope or ensure_baseline_loudness_envelope(
        args.baseline_manifest,
        loudness_jobs=getattr(args, "loudness_jobs", 0),
    )
    loudness_analyses: List[Dict[str, object]] = []
    loudness_by_source: Dict[str, Dict[str, object]] = {}
    metadata_cache = _metadata_cache_path_for_args(args)
    cache_hits = 0
    precomputed_hits = 0
    cache_misses: List[Path] = []
    for music in music_files:
        key = source_key(music)
        analysis = (
            precomputed_loudness_by_source.get(key)
            if precomputed_loudness_by_source is not None
            else None
        )
        if analysis is not None:
            precomputed_hits += 1
        else:
            analysis = _read_loudness_cache_entry(metadata_cache, music)
            if analysis is not None:
                cache_hits += 1
        if analysis is None:
            cache_misses.append(music)

        if analysis is not None:
            if analysis.get("status") != "ok":
                die(f"Could not measure loudness for {music}: {analysis.get('error')}")
            loudness_by_source[key] = analysis

    measured_analyses = _measure_loudness_cache_misses(
        cache_misses,
        args,
        ffmpeg,
        has_cache=metadata_cache is not None,
        allow_parallel=parallel_loudness,
    )
    for music in cache_misses:
        analysis = measured_analyses[source_key(music)]
        _write_loudness_cache_entry(metadata_cache, music, analysis)
        loudness_by_source[source_key(music)] = analysis

    for music in music_files:
        loudness_analyses.append(loudness_by_source[source_key(music)])
    loudness_profile = build_custom_set_loudness_profile(
        loudness_analyses,
        envelope,
        radio=radio,
        target_offset_lu=_args_loudness_offset_lu(args),
    )
    print("  Loudness matching: custom set profile ready.")
    if precomputed_loudness_by_source is not None:
        print(f"  Loudness cache: {precomputed_hits} precomputed hit(s).")
    if metadata_cache is not None and (cache_hits > 0 or cache_misses):
        print(f"  Loudness cache: {cache_hits} hit(s), {len(cache_misses)} measured + cached.")

    prepared_tracks: List[Dict[str, object]] = []
    for index, music in enumerate(music_files, start=1):
        artist, title = guess_metadata(music)
        prepared_wav = (
            prepared_dir
            / f"{index:02d}_{sanitize_token(artist, 'Artist')}_{sanitize_token(title, 'Track')}.wav"
        )
        before, after, loudness = prepare_loudness_matched_audio(
            music,
            prepared_wav,
            loudness_profile,
            ffmpeg=ffmpeg,
            input_analysis=loudness_by_source.get(source_key(music)),
            verify_output=False,
        )
        override = timing_override_for(timing_overrides, music)
        bpm_value = bpm_from_override(override, args.bpm)
        if _all_core_markers_overridden(override):
            timing = {}
            sr = int(after["sample_rate"])
        else:
            data, sr = sf.read(str(prepared_wav), dtype="float32", always_2d=True)
            timing = estimate_timing(data, sr, bpm=bpm_value)
        marker_args = argparse.Namespace(
            track_drop_sec=marker_seconds_from_override(override, "TrackDrop"),
            post_drop_sec=marker_seconds_from_override(override, "PostDrop"),
            track_loop_start_sec=marker_seconds_from_override(override, "TrackLoopStart"),
            track_loop_end_sec=marker_seconds_from_override(override, "TrackLoopEnd"),
            post_loop_start_sec=marker_seconds_from_override(override, "PostRaceLoopStart"),
            post_loop_end_sec=marker_seconds_from_override(override, "PostRaceLoopEnd"),
        )
        markers = build_markers(
            marker_args, timing, int(after["samples"]), int(after["sample_rate"])
        )
        prepared_tracks.append(
            {
                "source": str(music.resolve()),
                "prepared_wav": str(prepared_wav.resolve()),
                "display_name": title,
                "artist": artist,
                "sample_rate": int(after["sample_rate"]),
                "sample_length": int(after["samples"]),
                "markers": markers,
                "bpm": bpm_value,
                "timing_override": override is not None,
                "before": before,
                "after": after,
                "loudness": loudness,
            }
        )
        print(
            f"  [{index}/{len(music_files)}] {music.name} -> {prepared_wav.name} "
            f"({after['sample_rate']} Hz, {s2tc(int(after['samples']), int(after['sample_rate']))})"
            f"{' · saved timing' if override is not None else ''}"
        )
    for item in prepared_tracks:
        item["loudness_profile"] = loudness_profile
    return prepared_tracks


def build_radio_package_unit(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    root: ET.Element,
    radio: int,
    music_files: List[Path],
    playlist_types_by_source: Optional[Dict[str, List[str]]],
    playlist_slots_by_source: Optional[Dict[str, Dict[str, int]]],
    prepared_dir: Path,
    stage_root: Path,
    fsbank_out: Path,
    package_bank_dir: Path,
    ffmpeg: Optional[str],
    fsbankcl: Optional[str],
    timing_overrides: Dict[str, object],
    loudness_envelope: Optional[Dict[str, object]] = None,
    progress: Optional[_PackageProgressReporter] = None,
    precomputed_loudness_by_source: Optional[Dict[str, Dict[str, object]]] = None,
) -> Dict[str, object]:
    progress = progress or _PackageProgressReporter(False)
    station = find_station(root, radio)
    target_bank = resolve_target_bank_for_station(audio_dir, station, radio, args.bank)
    bank_info = parse_fsb5(target_bank)
    target_names = target_names_for_bank(station, bank_info, target_bank, args.baseline_manifest)
    replaceable_slots = playlist_entry_caps_for_sources(
        station,
        music_files,
        playlist_types_by_source,
        bank_info.num_samples,
    )

    if len(music_files) > bank_info.num_samples and not args.allow_truncate:
        die(
            f"{len(music_files)} music files were provided for R{radio}, but {target_bank.name} has "
            f"{bank_info.num_samples} slots. Use --allow-truncate to keep the first {bank_info.num_samples}."
        )
    music_files = music_files[: bank_info.num_samples]
    if not music_files:
        die(f"No music files assigned for R{radio}")

    print(f"Radio       : R{radio} {station.get('Name')}")
    print(f"Bank        : {target_bank}")
    print(f"Bank slots  : {bank_info.num_samples}")
    print(f"Music files : {len(music_files)}")

    with progress.stage(
        _radio_progress_step_id(radio, "prepare_audio"),
        summary=f"{len(music_files)} 首音频已准备",
    ):
        prepared_tracks = prepare_music_tracks(
            music_files,
            args,
            prepared_dir / f"R{radio}",
            timing_overrides,
            ffmpeg,
            radio=radio,
            loudness_envelope=loudness_envelope,
            parallel_loudness=precomputed_loudness_by_source is None,
            precomputed_loudness_by_source=precomputed_loudness_by_source,
        )

    bank_name = bank_name_from_path(target_bank)
    stage_dir = stage_root / bank_name
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True)

    playlist_types_by_source = playlist_types_by_source or {}
    playlist_slots_by_source = playlist_slots_by_source or {}
    assignments: List[Dict[str, object]] = []
    width = max(4, len(str(bank_info.num_samples)))
    with progress.stage(
        _radio_progress_step_id(radio, "stage_bank"),
        summary=f"{len(target_names)} 个 bank 槽位已 staged",
    ):
        for slot_index, target_sound_name in enumerate(target_names):
            source_index = slot_index % len(prepared_tracks)
            track = prepared_tracks[source_index]
            staged_wav = stage_dir / f"{slot_index + 1:0{width}d}.wav"
            shutil.copy2(track["prepared_wav"], staged_wav)
            playlist_types = playlist_types_by_source.get(
                source_key(Path(str(track["source"]))),
                list(PLAYLIST_TYPES),
            )
            playlist_slots = playlist_slots_by_source.get(
                source_key(Path(str(track["source"]))),
                {playlist_type: slot_index + 1 for playlist_type in playlist_types},
            )
            assignments.append(
                {
                    "slot_index": slot_index,
                    "target_sound_name": target_sound_name,
                    "staged_wav": str(staged_wav.resolve()),
                    "source_index": source_index,
                    "source": track["source"],
                    "playlist_entry": slot_index < len(prepared_tracks),
                    "playlist_types": playlist_types,
                    "playlist_slots": playlist_slots,
                    "display_name": track["display_name"],
                    "artist": track["artist"],
                    "sample_rate": track["sample_rate"],
                    "sample_length": track["sample_length"],
                    "markers": track["markers"],
                    "bpm": track["bpm"],
                }
            )

    rebuilt_bank = package_bank_dir / target_bank.name
    splice_stats: Optional[Dict[str, int]] = None
    pack_order: Optional[List[int]] = None
    if not args.skip_bank:
        if not fsbankcl:
            die(
                "fsbankcl not found. Pass --fsbankcl or add it to PATH. Use --skip-bank for XML/audio staging only."
            )
        with progress.stage(
            _radio_progress_step_id(radio, "rebuild_bank"),
            summary=target_bank.name,
        ):
            fsb_path = run_fsbankcl(fsbankcl, stage_dir, fsbank_out, args.quality)
            pack_order = detect_pack_order(fsb_path, bank_info.num_samples)
            if pack_order:
                print(
                    f"fsbank pack order detected: {pack_order[:16]}{' ...' if len(pack_order) > 16 else ''}"
                )
                ordered_names = [target_names[i] for i in pack_order]
            else:
                print("Could not detect fsbank pack order; assuming numeric stage order.")
                ordered_names = target_names
            new_fsb = rewrite_fsb5_names(fsb_path.read_bytes(), ordered_names)
            splice_stats = splice_fsb5_into_bank(target_bank, new_fsb, rebuilt_bank)
            print(f"Rebuilt bank: {rebuilt_bank}")
    else:
        progress.completed(
            _radio_progress_step_id(radio, "rebuild_bank"),
            status="skipped",
            summary="--skip-bank",
        )

    return {
        "radio": radio,
        "radio_code": radio_code_for_station(radio, station.get("Name", "")),
        "station": station.get("Name"),
        "source_bank": str(target_bank),
        "target_bank_name": target_bank.name,
        "bank_slots": bank_info.num_samples,
        "replaceable_slots": replaceable_slots,
        "pack_order": pack_order,
        "splice": splice_stats,
        "loudness_profile": prepared_tracks[0].get("loudness_profile") if prepared_tracks else None,
        "music": prepared_tracks,
        "assignments": assignments,
    }


def _build_radio_package_unit_worker(payload: Dict[str, object]) -> Dict[str, object]:
    raw_args = payload["args"]
    args = argparse.Namespace(**vars(raw_args))
    root = ET.fromstring(str(payload["root_xml"]))
    progress = (
        _QueuePackageProgressReporter(_RADIO_PROGRESS_QUEUE)
        if _RADIO_PROGRESS_QUEUE is not None
        else _PackageProgressReporter(False)
    )
    return build_radio_package_unit(
        args,
        Path(str(payload["game_dir"])),
        Path(str(payload["audio_dir"])),
        root,
        int(payload["radio"]),
        [Path(str(path)) for path in payload["sources"]],
        payload.get("playlist_types_by_source"),
        payload.get("playlist_slots_by_source"),
        Path(str(payload["prepared_dir"])),
        Path(str(payload["stage_root"])),
        Path(str(payload["fsbank_out"])),
        Path(str(payload["package_bank_dir"])),
        payload.get("ffmpeg"),
        payload.get("fsbankcl"),
        payload["timing_overrides"],
        payload.get("loudness_envelope"),
        progress,
        payload.get("precomputed_loudness_by_source"),
    )


def _playlist_type_counts_for_group(group: Dict[str, object]) -> Dict[str, int]:
    counts = {playlist_type: 0 for playlist_type in PLAYLIST_TYPES}
    playlist_types_by_source = group.get("playlist_types_by_source")
    if not isinstance(playlist_types_by_source, dict):
        playlist_types_by_source = {}
    for source in list(group["sources"]):
        key = source_key(Path(str(source)))
        raw_types = playlist_types_by_source.get(key, list(PLAYLIST_TYPES))
        playlist_types = raw_types if isinstance(raw_types, list) else list(PLAYLIST_TYPES)
        for raw_type in playlist_types:
            playlist_type = normalize_playlist_type(raw_type)
            counts[playlist_type] = counts.get(playlist_type, 0) + 1
    return counts


def preflight_build_package_from_plan(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    root: ET.Element,
    groups: List[Dict[str, object]],
) -> None:
    validate_language_settings(args, game_dir)
    for group in groups:
        radio = int(group["radio"])
        station = find_station(root, radio)
        target_bank = resolve_target_bank_for_station(audio_dir, station, radio, args.bank)
        bank_info = parse_fsb5(target_bank)
        target_names_for_bank(station, bank_info, target_bank, args.baseline_manifest)
        playlist_caps = playlist_entry_caps(station)
        music_files = list(group["sources"])
        if len(music_files) > bank_info.num_samples and not args.allow_truncate:
            die(
                f"{len(music_files)} music files were provided for R{radio}, but {target_bank.name} has "
                f"{bank_info.num_samples} slots. Use --allow-truncate to keep the first {bank_info.num_samples}."
            )
        if not music_files:
            die(f"No music files assigned for R{radio}")
        playlist_counts = _playlist_type_counts_for_group(group)
        for playlist_type, count in playlist_counts.items():
            cap = playlist_caps.get(playlist_type, 0) or bank_info.num_samples
            if count > cap:
                die(
                    f"{count} music files were assigned to R{radio} {playlist_type}, "
                    f"but the baseline playlist has only {cap} entries."
                )
        slots_by_source = group.get("playlist_slots_by_source")
        if not isinstance(slots_by_source, dict):
            continue
        for slots in slots_by_source.values():
            if not isinstance(slots, dict):
                continue
            for playlist_type, slot in slots.items():
                try:
                    slot_num = int(slot)
                except (TypeError, ValueError):
                    continue
                cap = (
                    playlist_caps.get(normalize_playlist_type(playlist_type), 0)
                    or bank_info.num_samples
                )
                if slot_num > cap:
                    die(
                        f"Playlist plan assigns R{radio} {playlist_type} slot {slot_num}, "
                        f"but the baseline playlist has only {cap} entries."
                    )


def package_language_settings(
    args: argparse.Namespace, game_dir: Path, package_string_dir: Path
) -> Optional[Dict[str, object]]:
    validate_language_settings(args, game_dir)
    if not args.source and not args.target:
        return None
    source_lang = normalize_text_language(args.source)
    target_lang = normalize_text_language(args.target)
    source_string_dir = (
        Path(args.source_string_tables_dir).expanduser()
        if args.source_string_tables_dir
        else string_tables_dir_for(game_dir)
    )
    source_table = source_string_dir / f"{source_lang}.zip"
    target_table = source_string_dir / f"{target_lang}.zip"
    package_string_dir.mkdir(parents=True, exist_ok=True)
    packaged_target = package_string_dir / f"{target_lang}.zip"
    shutil.copy2(source_table, packaged_target)
    print(f"Packaged language: {source_lang} display -> {target_lang} voice")
    return {
        "source_lang": source_lang,
        "target_lang": target_lang,
        "source_string_tables_dir": str(source_string_dir.resolve()),
        "source_table": str(source_table.resolve()),
        "target_table": str(target_table.resolve()),
        "packaged_table": str(packaged_target.resolve()),
        "preferred_lang": target_lang,
        "source_md5": md5_file(source_table),
        "target_original_md5": md5_file(target_table),
        "package_md5": md5_file(packaged_target),
    }


def validate_language_settings(args: argparse.Namespace, game_dir: Path) -> None:
    if not args.source and not args.target:
        return
    if not args.source or not args.target:
        die("Pass both --source and --target when packaging language settings.")
    if not args.source_string_tables_dir:
        die(
            "Packaging language settings requires trusted baseline string tables. "
            "Pass --source-string-tables-dir from the baseline directory."
        )
    source_lang = normalize_text_language(args.source)
    target_lang = normalize_text_language(args.target)
    source_string_dir = (
        Path(args.source_string_tables_dir).expanduser()
        if args.source_string_tables_dir
        else string_tables_dir_for(game_dir)
    )
    source_table = source_string_dir / f"{source_lang}.zip"
    target_table = source_string_dir / f"{target_lang}.zip"
    if not source_table.exists():
        die(f"Source language table not found: {source_table}")
    if not target_table.exists():
        die(f"Target language table not found: {target_table}")


def cmd_build_current_radio_package(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    radio_info: Path,
    root: ET.Element,
    progress: Optional[_PackageProgressReporter] = None,
) -> int:
    progress = progress or _PackageProgressReporter(False)
    station = find_station(root, args.radio)
    progress.plan(
        _package_progress_plan(
            args,
            [(args.radio, 0, station.get("Name"))],
            current_radio_passthrough=True,
        )
    )
    out_dir = Path(args.out_dir).expanduser()
    package_root = out_dir / "package"
    package_audio = package_root / "media" / "audio"
    package_bank_dir = package_audio / "FMODBanks"
    package_string_dir = package_root / "media" / "Stripped" / "StringTables"
    with progress.stage("inspect_inputs"):
        for path in (package_audio, package_bank_dir):
            path.mkdir(parents=True, exist_ok=True)
        target_bank = resolve_target_bank_for_station(audio_dir, station, args.radio, args.bank)
        bank_info = parse_fsb5(target_bank)
        replaceable_slots = playlist_entry_caps_for_types(
            station,
            PLAYLIST_TYPES,
            bank_info.num_samples,
        )

    with progress.stage("package_language"):
        language_manifest = package_language_settings(args, game_dir, package_string_dir)
        if language_manifest is None:
            die(
                "No music files or playlist assignments were provided. Assign at least one track, "
                "or pass --source and --target to build a baseline-radio package."
            )

    with progress.stage("copy_baseline_radio", summary=target_bank.name):
        packaged_bank = package_bank_dir / target_bank.name
        shutil.copy2(target_bank, packaged_bank)
        print(f"Packaged baseline bank: {target_bank.name}")

        copied_radio_info: List[str] = []
        for source_xml in radio_info_files(audio_dir):
            target_xml = package_audio / source_xml.name
            shutil.copy2(source_xml, target_xml)
            parse_xml(target_xml)
            copied_radio_info.append(source_xml.name)
            print(f"  copied {source_xml.name} unchanged")

    package_manifest: Dict[str, object] = {
        "schema_version": 2,
        "current_radio_passthrough": True,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "game_dir": str(game_dir),
        **_package_game_version_fields(game_dir),
        "source_audio_dir": str(audio_dir.resolve()),
        "source_radio_info": str(radio_info),
        "playlist_plan": None,
        "radio": args.radio,
        "radio_code": radio_code_for_station(args.radio, station.get("Name", "")),
        "station": station.get("Name"),
        "source_bank": str(target_bank),
        "target_bank_name": target_bank.name,
        "bank_slots": bank_info.num_samples,
        "replaceable_slots": replaceable_slots,
        "playlist_mode": args.playlist_mode,
        "quality": args.quality,
        "skip_bank": False,
        "timing_manifest": None,
        "runtime_verified": True,
        "runtime_warning": None,
        "radios": [
            {
                "radio": args.radio,
                "radio_code": radio_code_for_station(args.radio, station.get("Name", "")),
                "station": station.get("Name"),
                "source_bank": str(target_bank),
                "target_bank_name": target_bank.name,
                "bank_slots": bank_info.num_samples,
                "replaceable_slots": replaceable_slots,
                "pack_order": None,
                "splice": None,
                "loudness_profile": None,
                "music": [],
                "assignments": [],
            }
        ],
        "language": language_manifest,
        "xml_patch_totals": {
            "samples_patched": 0,
            "missing_samples": 0,
            "playlist_entries_added": 0,
            "playlist_entries_removed": 0,
        },
    }
    with progress.stage("complete_package", summary="manifest + MD5"):
        apply_baseline_completion(package_manifest, package_root, args)
        package_manifest["package_files"] = package_file_fingerprints(package_root)
        manifest_path = package_root / "fh_radio_studio_package_manifest.json"
        write_json(manifest_path, package_manifest)
        instructions = [
            "FH Radio Studio baseline-radio package",
            "=" * 35,
            f"Radio  : R{args.radio} {station.get('Name')}",
            f"Bank   : {target_bank.name}",
            f"Display: {language_manifest['source_lang']}",
            f"Voice  : {language_manifest['target_lang']}",
            "",
            "RadioInfo and the selected bank are copied from the trusted baseline unchanged.",
            "Deploy also writes UserPreferredLang when language settings are present.",
            "",
            "Package files:",
            f"  {package_audio}",
            f"  {package_string_dir}",
            f"  {manifest_path}",
        ]
        write_text(package_root / "INSTALL_README.txt", "\n".join(instructions) + "\n")

    print(f"Package manifest: {manifest_path}")
    print(f"Baseline-radio package built with {len(copied_radio_info)} RadioInfo file(s).")
    return 0


def _baseline_audio_dir_from_manifest(baseline_manifest: Optional[str]) -> Optional[Path]:
    if not baseline_manifest:
        return None
    manifest_path = Path(baseline_manifest).expanduser()
    audio_dir = manifest_path.parent / "media" / "audio"
    return audio_dir if audio_dir.is_dir() else None


def _baseline_string_tables_dir_from_manifest(baseline_manifest: Optional[str]) -> Optional[Path]:
    if not baseline_manifest:
        return None
    manifest_path = Path(baseline_manifest).expanduser()
    string_dir = manifest_path.parent / "media" / "Stripped" / "StringTables"
    return string_dir if string_dir.is_dir() else None


def cmd_build_baseline_restore_package(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    root: ET.Element,
    restore_targets: List[Dict[str, object]],
    progress: Optional[_PackageProgressReporter] = None,
) -> int:
    progress = progress or _PackageProgressReporter(False)
    if not getattr(args, "baseline_manifest", None):
        die("A pristine baseline manifest is required when restoring builtin playlist targets.")
    if args.bank and len(restore_targets) > 1:
        die("--bank can only be used with a single restored radio")

    baseline_audio = _baseline_audio_dir_from_manifest(args.baseline_manifest) or audio_dir
    radio_counts = [
        (
            int(target["radio"]),
            0,
            find_station(root, int(target["radio"])).get("Name"),
        )
        for target in restore_targets
    ]
    progress.plan(
        _package_progress_plan(
            args,
            radio_counts,
            current_radio_passthrough=True,
        )
    )

    out_dir = Path(args.out_dir).expanduser()
    package_root = out_dir / "package"
    package_audio = package_root / "media" / "audio"
    package_bank_dir = package_audio / "FMODBanks"
    package_string_dir = package_root / "media" / "Stripped" / "StringTables"
    restored_units: List[Dict[str, object]] = []

    with progress.stage("inspect_inputs"):
        for path in (package_audio, package_bank_dir):
            path.mkdir(parents=True, exist_ok=True)
        for target in restore_targets:
            radio = int(target["radio"])
            station = find_station(root, radio)
            target_bank = resolve_target_bank_for_station(
                baseline_audio,
                station,
                radio,
                args.bank,
            )
            bank_info = parse_fsb5(target_bank)
            restored_playlist_types = list(target.get("playlist_types") or [])
            replaceable_slots = playlist_entry_caps_for_types(
                station,
                restored_playlist_types or PLAYLIST_TYPES,
                bank_info.num_samples,
            )
            restored_units.append(
                {
                    "radio": radio,
                    "radio_code": radio_code_for_station(radio, station.get("Name", "")),
                    "station": station.get("Name"),
                    "source_bank": str(target_bank),
                    "target_bank_name": target_bank.name,
                    "bank_slots": bank_info.num_samples,
                    "replaceable_slots": replaceable_slots,
                    "restored_playlist_types": restored_playlist_types,
                    "pack_order": None,
                    "splice": None,
                    "loudness_profile": None,
                    "music": [],
                    "assignments": [],
                }
            )

    with progress.stage("package_language"):
        language_manifest = package_language_settings(args, game_dir, package_string_dir)

    with progress.stage("copy_baseline_radio", summary=f"{len(restored_units)} radio(s)"):
        copied_radio_info: List[str] = []
        for source_xml in radio_info_files(baseline_audio):
            target_xml = package_audio / source_xml.name
            shutil.copy2(source_xml, target_xml)
            parse_xml(target_xml)
            copied_radio_info.append(source_xml.name)
            print(f"  copied baseline {source_xml.name}")
        for unit in restored_units:
            source_bank = Path(str(unit["source_bank"]))
            target_bank = package_bank_dir / source_bank.name
            if not target_bank.exists():
                shutil.copy2(source_bank, target_bank)
                print(f"  copied baseline {source_bank.name}")

    package_manifest: Dict[str, object] = {
        "schema_version": 2,
        "baseline_restore": True,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "game_dir": str(game_dir),
        **_package_game_version_fields(game_dir),
        "source_audio_dir": str(baseline_audio.resolve()),
        "source_radio_info": str(default_radio_info(baseline_audio)),
        "playlist_plan": (
            str(Path(args.playlist_plan).expanduser().resolve()) if args.playlist_plan else None
        ),
        "radio": restored_units[0]["radio"] if len(restored_units) == 1 else None,
        "station": (
            restored_units[0]["station"]
            if len(restored_units) == 1
            else f"{len(restored_units)} restored radios"
        ),
        "target_bank_name": ", ".join(str(item["target_bank_name"]) for item in restored_units),
        "bank_slots": sum(int(item["bank_slots"]) for item in restored_units),
        "replaceable_slots": aggregate_replaceable_slots(restored_units),
        "playlist_mode": args.playlist_mode,
        "quality": args.quality,
        "skip_bank": False,
        "timing_manifest": None,
        "runtime_verified": True,
        "runtime_warning": None,
        "radios": restored_units,
        "restored_radios": [
            {
                "radio": item["radio"],
                "radio_code": item["radio_code"],
                "station": item["station"],
                "playlist_types": item.get("restored_playlist_types") or [],
            }
            for item in restored_units
        ],
        "xml_patch_totals": {
            "samples_patched": 0,
            "missing_samples": 0,
            "playlist_entries_added": 0,
            "playlist_entries_removed": 0,
        },
    }
    if language_manifest is not None:
        package_manifest["language"] = language_manifest

    with progress.stage("complete_package", summary="manifest + MD5"):
        apply_baseline_completion(package_manifest, package_root, args)
        package_manifest["package_files"] = package_file_fingerprints(package_root)
        manifest_path = package_root / "fh_radio_studio_package_manifest.json"
        write_json(manifest_path, package_manifest)
        instructions = [
            "FH Radio Studio builtin restore package",
            "=" * 39,
            f"Radios: {', '.join('R' + str(item['radio']) + ' ' + str(item['station']) for item in restored_units)}",
            "",
            "RadioInfo and restored banks are copied from the pristine baseline.",
            "Deploy through FH Radio Studio to write the package into the game directory.",
            "",
            "Package files:",
            f"  {package_audio}",
            f"  {manifest_path}",
        ]
        write_text(package_root / "INSTALL_README.txt", "\n".join(instructions) + "\n")

    print(f"Package manifest: {manifest_path}")
    print(f"Builtin restore package built with {len(restored_units)} restored radio(s).")
    return 0


def _build_radio_package_units_from_plan(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    root: ET.Element,
    groups: List[Dict[str, object]],
    prepared_dir: Path,
    stage_root: Path,
    fsbank_out: Path,
    package_bank_dir: Path,
    ffmpeg: Optional[str],
    fsbankcl: Optional[str],
    timing_overrides: Dict[str, object],
    loudness_envelope: Dict[str, object],
    precomputed_loudness_by_source: Dict[str, Dict[str, object]],
    progress: _PackageProgressReporter,
) -> List[Dict[str, object]]:
    worker_count = _radio_package_worker_count(len(groups))
    if worker_count <= 1:
        return [
            build_radio_package_unit(
                args,
                game_dir,
                audio_dir,
                root,
                int(group["radio"]),
                list(group["sources"]),
                group.get("playlist_types_by_source"),
                group.get("playlist_slots_by_source"),
                prepared_dir,
                stage_root,
                fsbank_out,
                package_bank_dir,
                ffmpeg,
                fsbankcl,
                timing_overrides,
                loudness_envelope,
                progress,
                precomputed_loudness_by_source,
            )
            for group in groups
        ]

    print(
        f"Radio package build: building {len(groups)} radio(s) with " f"{worker_count} process(es)."
    )
    root_xml = ET.tostring(root, encoding="unicode")
    results: List[Optional[Dict[str, object]]] = [None] * len(groups)
    first_error: Optional[Exception] = None

    with mp.Manager() as manager:
        progress_queue = manager.Queue()
        with ProcessPoolExecutor(
            max_workers=worker_count,
            initializer=_init_radio_package_worker,
            initargs=(progress_queue,),
        ) as pool:
            futures = {}
            for index, group in enumerate(groups):
                radio = int(group["radio"])
                payload: Dict[str, object] = {
                    "args": argparse.Namespace(
                        **{key: value for key, value in vars(args).items() if key != "func"}
                    ),
                    "game_dir": str(game_dir),
                    "audio_dir": str(audio_dir),
                    "root_xml": root_xml,
                    "radio": radio,
                    "sources": [str(path) for path in list(group["sources"])],
                    "playlist_types_by_source": group.get("playlist_types_by_source"),
                    "playlist_slots_by_source": group.get("playlist_slots_by_source"),
                    "prepared_dir": str(prepared_dir),
                    "stage_root": str(stage_root),
                    "fsbank_out": str(fsbank_out / f"R{radio}"),
                    "package_bank_dir": str(package_bank_dir),
                    "ffmpeg": ffmpeg,
                    "fsbankcl": fsbankcl,
                    "timing_overrides": timing_overrides,
                    "loudness_envelope": loudness_envelope,
                    "precomputed_loudness_by_source": precomputed_loudness_by_source,
                }
                futures[pool.submit(_build_radio_package_unit_worker, payload)] = index

            pending = set(futures)
            while pending:
                done, pending = wait(pending, timeout=0.1, return_when=FIRST_COMPLETED)
                _drain_radio_progress_queue(progress_queue, progress)
                for future in done:
                    index = futures[future]
                    try:
                        results[index] = future.result()
                    except Exception as exc:
                        if first_error is None:
                            first_error = exc

            _drain_radio_progress_queue(progress_queue, progress)

    if first_error is not None:
        raise first_error
    return [item for item in results if item is not None]


def cmd_build_package_from_plan(
    args: argparse.Namespace,
    game_dir: Path,
    audio_dir: Path,
    radio_info: Path,
    root: ET.Element,
    groups: List[Dict[str, object]],
    restore_targets: Optional[List[Dict[str, object]]] = None,
    progress: Optional[_PackageProgressReporter] = None,
) -> int:
    progress = progress or _PackageProgressReporter(False)
    restore_targets = restore_targets or []
    song_loudness_sources = _unique_music_sources(groups)
    radio_counts = [
        (
            int(group["radio"]),
            len(list(group["sources"])),
            find_station(root, int(group["radio"])).get("Name"),
        )
        for group in groups
    ]
    progress.plan(
        _package_progress_plan(
            args,
            radio_counts,
            song_loudness_count=len(song_loudness_sources),
        )
    )
    if args.bank and len(groups) + len(restore_targets) > 1:
        die("--bank can only be used with a single target radio")
    if restore_targets:
        if not getattr(args, "baseline_manifest", None):
            die("A pristine baseline manifest is required when restoring builtin playlist targets.")
        if not getattr(args, "source_audio_dir", None):
            die(
                "Restoring builtin playlist targets requires --source-audio-dir "
                "pointing at the pristine baseline media/audio directory."
            )
    with progress.stage("inspect_inputs"):
        preflight_build_package_from_plan(args, game_dir, audio_dir, root, groups)

    timing_overrides = load_timing_overrides(args.timing_manifest)
    out_dir = Path(args.out_dir).expanduser()
    prepared_dir = out_dir / "work" / "prepared"
    stage_root = out_dir / "work" / "fsbank_stage"
    fsbank_out = out_dir / "work" / "fsbank_out"
    package_audio = out_dir / "package" / "media" / "audio"
    package_bank_dir = package_audio / "FMODBanks"
    package_xml_dir = package_audio
    package_string_dir = out_dir / "package" / "media" / "Stripped" / "StringTables"
    for path in (prepared_dir, stage_root, fsbank_out, package_bank_dir, package_xml_dir):
        path.mkdir(parents=True, exist_ok=True)

    ffmpeg = (
        find_executable(args.ffmpeg, "ffmpeg") if (args.ffmpeg or shutil.which("ffmpeg")) else None
    )
    fsbankcl = None if args.skip_bank else find_executable(args.fsbankcl, "fsbankcl")
    if not args.skip_bank and not fsbankcl:
        die(
            "fsbankcl not found. Pass --fsbankcl or add it to PATH. Use --skip-bank for XML/audio staging only."
        )

    print(f"Game dir    : {game_dir}")
    print(f"Source audio: {audio_dir}")
    print(f"Playlist    : {args.playlist_plan or args.playlist_from_package}")
    print(f"Radios      : {len(groups)}")
    print(f"Loudness    : baseline median +{_args_loudness_offset_lu(args):g} LU")
    if timing_overrides:
        print(f"Timing cfg  : {len(timing_overrides)} saved track config(s)")
    print(f"Out dir     : {out_dir}")

    loudness_envelope = _ensure_package_loudness_envelope(args, progress)
    precomputed_loudness_by_source = _build_package_song_loudness_cache(
        song_loudness_sources,
        args,
        ffmpeg,
        progress,
    )
    radio_packages = _build_radio_package_units_from_plan(
        args,
        game_dir,
        audio_dir,
        root,
        groups,
        prepared_dir,
        stage_root,
        fsbank_out,
        package_bank_dir,
        ffmpeg,
        fsbankcl,
        timing_overrides,
        loudness_envelope,
        precomputed_loudness_by_source,
        progress,
    )

    if args.source or args.target:
        with progress.stage("package_language"):
            language_manifest = package_language_settings(args, game_dir, package_string_dir)
    else:
        language_manifest = package_language_settings(args, game_dir, package_string_dir)
    first_radio = radio_packages[0]
    package_manifest: Dict[str, object] = {
        "schema_version": 2,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "game_dir": str(game_dir),
        **_package_game_version_fields(game_dir),
        "source_audio_dir": str(audio_dir.resolve()),
        "source_radio_info": str(radio_info),
        "playlist_plan": (
            str(Path(args.playlist_plan).expanduser().resolve()) if args.playlist_plan else None
        ),
        "radio": first_radio["radio"] if len(radio_packages) == 1 else None,
        "station": (
            first_radio["station"] if len(radio_packages) == 1 else f"{len(radio_packages)} radios"
        ),
        "target_bank_name": ", ".join(str(item["target_bank_name"]) for item in radio_packages),
        "bank_slots": sum(int(item["bank_slots"]) for item in radio_packages),
        "replaceable_slots": aggregate_replaceable_slots(radio_packages),
        "playlist_mode": args.playlist_mode,
        "quality": args.quality,
        "loudness_mode": "custom-set",
        "loudness_offset_lu": round(_args_loudness_offset_lu(args), 3),
        "skip_bank": args.skip_bank,
        "timing_manifest": (
            str(Path(args.timing_manifest).expanduser().resolve()) if args.timing_manifest else None
        ),
        "runtime_verified": False,
        "runtime_warning": (
            "Generated bank has only been tool-validated. Do not deploy unless "
            "you intentionally accept the risk or have verified this package in game."
        ),
        "radios": radio_packages,
    }
    if restore_targets:
        package_manifest["restored_radios"] = [
            {
                "radio": int(target["radio"]),
                "radio_code": radio_code_for_station(
                    int(target["radio"]),
                    find_station(root, int(target["radio"])).get("Name", ""),
                ),
                "station": find_station(root, int(target["radio"])).get("Name"),
                "playlist_types": list(target.get("playlist_types") or []),
            }
            for target in restore_targets
        ]
    if language_manifest is not None:
        package_manifest["language"] = language_manifest

    totals = {
        "samples_patched": 0,
        "missing_samples": 0,
        "playlist_entries_added": 0,
        "playlist_entries_removed": 0,
    }
    with progress.stage("patch_xml"):
        for source_xml in radio_info_files(audio_dir):
            tree = parse_xml(source_xml)
            stats = patch_package_xml_tree(tree, package_manifest, args.playlist_mode)
            for key, value in stats.items():
                totals[key] += value
            ET.indent(tree, space="  ")
            target_xml = package_xml_dir / source_xml.name
            tree.write(
                str(target_xml), encoding="utf-8", xml_declaration=True, short_empty_elements=True
            )
            parse_xml(target_xml)
            print(f"  patched {source_xml.name}: {stats}")

    package_manifest["xml_patch_totals"] = totals
    with progress.stage("complete_package", summary="manifest + MD5"):
        apply_baseline_completion(package_manifest, out_dir / "package", args)
        package_manifest["package_files"] = package_file_fingerprints(out_dir / "package")
        manifest_path = out_dir / "package" / "fh_radio_studio_package_manifest.json"
        write_json(manifest_path, package_manifest)
        instructions = [
            "FH Radio Studio package",
            "=" * 24,
            f"Radios: {', '.join('R' + str(item['radio']) + ' ' + str(item['station']) for item in radio_packages)}",
            f"Banks : {', '.join(str(item['target_bank_name']) for item in radio_packages)}",
            "",
            "Copy the package/media folder into the FH6 game root only after backing up originals.",
            "Recommended test path: offline / solo, game closed. DJ Lite end cues are generated automatically.",
            "",
            "Package files:",
            f"  {package_audio}",
            f"  {manifest_path}",
        ]
        if args.skip_bank:
            instructions.append("")
            instructions.append(
                "Bank rebuild was skipped; this package only contains patched XML and prepared WAV staging files."
            )
        write_text(out_dir / "package" / "INSTALL_README.txt", "\n".join(instructions) + "\n")

    print(f"Package manifest: {manifest_path}")
    print(f"XML totals      : {totals}")
    if args.skip_bank:
        print("Bank rebuild skipped.")
    return 0


def cmd_build_package(args: argparse.Namespace) -> int:
    progress = _PackageProgressReporter(bool(getattr(args, "progress_jsonl", False)))
    game_dir = resolve_game_dir(args.game_dir)
    if not getattr(args, "baseline_manifest", None):
        die(
            "A trusted baseline manifest is required to build a package. "
            "Current game files are not used as package source."
        )
    baseline_manifest = Path(args.baseline_manifest).expanduser()
    if not baseline_manifest.is_file():
        die(f"Baseline manifest not found: {baseline_manifest}")
    audio_dir = Path(args.source_audio_dir).expanduser() if args.source_audio_dir else None
    if audio_dir is None:
        audio_dir = _baseline_audio_dir_from_manifest(str(baseline_manifest))
    if audio_dir is None:
        die(
            "Trusted baseline audio directory not found. Pass --source-audio-dir "
            "pointing at the baseline media/audio directory."
        )
    if not args.source_string_tables_dir:
        string_tables_dir = _baseline_string_tables_dir_from_manifest(str(baseline_manifest))
        if string_tables_dir is not None:
            args.source_string_tables_dir = str(string_tables_dir)
    if not audio_dir.is_dir():
        die(f"Source audio directory not found: {audio_dir}")
    radio_info = default_radio_info(audio_dir)
    root = parse_xml(radio_info).getroot()
    restore_targets = load_playlist_plan_builtin_targets(args.playlist_plan, root)
    restore_radios = {int(target["radio"]) for target in restore_targets}
    playlist_groups = load_playlist_plan_groups(
        args.playlist_plan,
        root,
        skip_radios=restore_radios,
    )
    if not playlist_groups and getattr(args, "playlist_from_package", None):
        playlist_groups = load_playlist_groups_from_package(args.playlist_from_package, root)
    if playlist_groups:
        return cmd_build_package_from_plan(
            args,
            game_dir,
            audio_dir,
            radio_info,
            root,
            playlist_groups,
            restore_targets,
            progress,
        )
    if restore_targets:
        return cmd_build_baseline_restore_package(
            args,
            game_dir,
            audio_dir,
            root,
            restore_targets,
            progress,
        )
    if not args.music:
        if args.source or args.target:
            return cmd_build_current_radio_package(
                args, game_dir, audio_dir, radio_info, root, progress
            )
        die(
            "No music files or playlist assignments were provided. Assign at least one track in the playlist draft before building a radio package."
        )

    station = find_station(root, args.radio)
    target_bank = resolve_target_bank_for_station(audio_dir, station, args.radio, args.bank)
    bank_info = parse_fsb5(target_bank)
    target_names = target_names_for_bank(station, bank_info, target_bank, args.baseline_manifest)
    playlist_cap = playlist_entry_cap_for_types(
        station,
        PLAYLIST_TYPES,
        bank_info.num_samples,
    )
    replaceable_slots = playlist_entry_caps_for_types(
        station,
        PLAYLIST_TYPES,
        bank_info.num_samples,
    )
    input_cap = min(bank_info.num_samples, playlist_cap)

    music_files = collect_music_inputs(args.music)
    if len(music_files) > input_cap and not args.allow_truncate:
        die(
            f"{len(music_files)} music files were provided, but {target_bank.name} has "
            f"{bank_info.num_samples} bank slots and the baseline playlist has "
            f"{playlist_cap} entries. Use --allow-truncate to keep the first {input_cap}."
        )
    music_files = music_files[:input_cap]
    progress.plan(
        _package_progress_plan(args, [(args.radio, len(music_files), station.get("Name"))])
    )
    with progress.stage("inspect_inputs"):
        timing_overrides = load_timing_overrides(args.timing_manifest)

        out_dir = Path(args.out_dir).expanduser()
        prepared_dir = out_dir / "work" / "prepared"
        stage_root = out_dir / "work" / "fsbank_stage"
        fsbank_out = out_dir / "work" / "fsbank_out"
        package_audio = out_dir / "package" / "media" / "audio"
        package_bank_dir = package_audio / "FMODBanks"
        package_xml_dir = package_audio
        package_string_dir = out_dir / "package" / "media" / "Stripped" / "StringTables"
        for path in (prepared_dir, stage_root, fsbank_out, package_bank_dir, package_xml_dir):
            path.mkdir(parents=True, exist_ok=True)

        ffmpeg = (
            find_executable(args.ffmpeg, "ffmpeg")
            if (args.ffmpeg or shutil.which("ffmpeg"))
            else None
        )
        fsbankcl = None if args.skip_bank else find_executable(args.fsbankcl, "fsbankcl")
        if not args.skip_bank and not fsbankcl:
            die(
                "fsbankcl not found. Pass --fsbankcl or add it to PATH. Use --skip-bank for XML/audio staging only."
            )

    print(f"Game dir    : {game_dir}")
    print(f"Source audio: {audio_dir}")
    print(f"Radio       : R{args.radio} {station.get('Name')}")
    print(f"Bank        : {target_bank}")
    print(f"Bank slots  : {bank_info.num_samples}")
    print(f"Music files : {len(music_files)}")
    print(f"Loudness    : baseline median +{_args_loudness_offset_lu(args):g} LU")
    if timing_overrides:
        print(f"Timing cfg  : {len(timing_overrides)} saved track config(s)")
    print(f"Out dir     : {out_dir}")

    loudness_envelope = _ensure_package_loudness_envelope(args, progress)
    prepared_tracks: List[Dict[str, object]] = []
    with progress.stage(
        _radio_progress_step_id(args.radio, "prepare_audio"),
        summary=f"{len(music_files)} 首音频已准备",
    ):
        prepared_tracks = prepare_music_tracks(
            music_files,
            args,
            prepared_dir,
            timing_overrides,
            ffmpeg,
            radio=args.radio,
            loudness_envelope=loudness_envelope,
        )

    bank_name = bank_name_from_path(target_bank)
    stage_dir = stage_root / bank_name
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True)

    assignments: List[Dict[str, object]] = []
    width = max(4, len(str(bank_info.num_samples)))
    with progress.stage(
        _radio_progress_step_id(args.radio, "stage_bank"),
        summary=f"{len(target_names)} 个 bank 槽位已 staged",
    ):
        for slot_index, target_sound_name in enumerate(target_names):
            source_index = slot_index % len(prepared_tracks)
            track = prepared_tracks[source_index]
            staged_wav = stage_dir / f"{slot_index + 1:0{width}d}.wav"
            shutil.copy2(track["prepared_wav"], staged_wav)
            assignments.append(
                {
                    "slot_index": slot_index,
                    "target_sound_name": target_sound_name,
                    "staged_wav": str(staged_wav.resolve()),
                    "source_index": source_index,
                    "source": track["source"],
                    "playlist_entry": slot_index < len(prepared_tracks),
                    "playlist_types": list(PLAYLIST_TYPES),
                    "playlist_slots": {
                        playlist_type: slot_index + 1 for playlist_type in PLAYLIST_TYPES
                    },
                    "display_name": track["display_name"],
                    "artist": track["artist"],
                    "sample_rate": track["sample_rate"],
                    "sample_length": track["sample_length"],
                    "markers": track["markers"],
                    "bpm": track["bpm"],
                }
            )

    rebuilt_bank = package_bank_dir / target_bank.name
    splice_stats: Optional[Dict[str, int]] = None
    pack_order: Optional[List[int]] = None
    if not args.skip_bank:
        with progress.stage(
            _radio_progress_step_id(args.radio, "rebuild_bank"),
            summary=target_bank.name,
        ):
            fsb_path = run_fsbankcl(fsbankcl, stage_dir, fsbank_out, args.quality)
            pack_order = detect_pack_order(fsb_path, bank_info.num_samples)
            if pack_order:
                print(
                    f"fsbank pack order detected: {pack_order[:16]}{' ...' if len(pack_order) > 16 else ''}"
                )
                ordered_names = [target_names[i] for i in pack_order]
            else:
                print("Could not detect fsbank pack order; assuming numeric stage order.")
                ordered_names = target_names
            new_fsb = rewrite_fsb5_names(fsb_path.read_bytes(), ordered_names)
            splice_stats = splice_fsb5_into_bank(target_bank, new_fsb, rebuilt_bank)
            print(f"Rebuilt bank: {rebuilt_bank}")
    else:
        progress.completed(
            _radio_progress_step_id(args.radio, "rebuild_bank"),
            status="skipped",
            summary="--skip-bank",
        )

    radio_package = {
        "radio": args.radio,
        "radio_code": radio_code_for_station(args.radio, station.get("Name", "")),
        "station": station.get("Name"),
        "source_bank": str(target_bank),
        "target_bank_name": target_bank.name,
        "bank_slots": bank_info.num_samples,
        "replaceable_slots": replaceable_slots,
        "pack_order": pack_order,
        "splice": splice_stats,
        "loudness_profile": prepared_tracks[0].get("loudness_profile") if prepared_tracks else None,
        "music": prepared_tracks,
        "assignments": assignments,
    }
    package_manifest = {
        "schema_version": 2,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "game_dir": str(game_dir),
        **_package_game_version_fields(game_dir),
        "source_audio_dir": str(audio_dir.resolve()),
        "radio": args.radio,
        "radio_code": radio_package["radio_code"],
        "station": station.get("Name"),
        "source_radio_info": str(radio_info),
        "source_bank": str(target_bank),
        "target_bank_name": target_bank.name,
        "bank_slots": bank_info.num_samples,
        "replaceable_slots": replaceable_slots,
        "playlist_mode": args.playlist_mode,
        "quality": args.quality,
        "loudness_mode": "custom-set",
        "loudness_offset_lu": round(_args_loudness_offset_lu(args), 3),
        "skip_bank": args.skip_bank,
        "timing_manifest": (
            str(Path(args.timing_manifest).expanduser().resolve()) if args.timing_manifest else None
        ),
        "runtime_verified": False,
        "runtime_warning": (
            "Generated bank has only been tool-validated. Do not deploy unless "
            "you intentionally accept the risk or have verified this package in game."
        ),
        "radios": [radio_package],
    }

    language_manifest: Optional[Dict[str, object]] = None
    if args.source or args.target:
        with progress.stage("package_language"):
            if not args.source or not args.target:
                die("Pass both --source and --target when packaging language settings.")
            source_lang = normalize_text_language(args.source)
            target_lang = normalize_text_language(args.target)
            source_string_dir = (
                Path(args.source_string_tables_dir).expanduser()
                if args.source_string_tables_dir
                else string_tables_dir_for(game_dir)
            )
            source_table = source_string_dir / f"{source_lang}.zip"
            target_table = source_string_dir / f"{target_lang}.zip"
            if not source_table.exists():
                die(f"Source language table not found: {source_table}")
            if not target_table.exists():
                die(f"Target language table not found: {target_table}")
            package_string_dir.mkdir(parents=True, exist_ok=True)
            packaged_target = package_string_dir / f"{target_lang}.zip"
            shutil.copy2(source_table, packaged_target)
            language_manifest = {
                "source_lang": source_lang,
                "target_lang": target_lang,
                "source_string_tables_dir": str(source_string_dir.resolve()),
                "source_table": str(source_table.resolve()),
                "target_table": str(target_table.resolve()),
                "packaged_table": str(packaged_target.resolve()),
                "preferred_lang": target_lang,
                "source_md5": md5_file(source_table),
                "target_original_md5": md5_file(target_table),
                "package_md5": md5_file(packaged_target),
            }
            package_manifest["language"] = language_manifest
            print(f"Packaged language: {source_lang} display -> {target_lang} voice")

    totals = {
        "samples_patched": 0,
        "missing_samples": 0,
        "playlist_entries_added": 0,
        "playlist_entries_removed": 0,
    }
    with progress.stage("patch_xml"):
        for source_xml in radio_info_files(audio_dir):
            tree = parse_xml(source_xml)
            stats = patch_package_xml_tree(tree, package_manifest, args.playlist_mode)
            for key, value in stats.items():
                totals[key] += value
            ET.indent(tree, space="  ")
            target_xml = package_xml_dir / source_xml.name
            tree.write(
                str(target_xml), encoding="utf-8", xml_declaration=True, short_empty_elements=True
            )
            parse_xml(target_xml)
            print(f"  patched {source_xml.name}: {stats}")

    package_manifest["xml_patch_totals"] = totals
    with progress.stage("complete_package", summary="manifest + MD5"):
        apply_baseline_completion(package_manifest, out_dir / "package", args)
        package_manifest["package_files"] = package_file_fingerprints(out_dir / "package")
        manifest_path = out_dir / "package" / "fh_radio_studio_package_manifest.json"
        write_json(manifest_path, package_manifest)
        instructions = [
            "FH Radio Studio package",
            "=" * 24,
            f"Radio: R{args.radio} {station.get('Name')}",
            f"Bank : {target_bank.name}",
            "",
            "Copy the package/media folder into the FH6 game root only after backing up originals.",
            "Recommended test path: offline / solo, game closed. DJ Lite end cues are generated automatically.",
            "",
            "Package files:",
            f"  {package_audio}",
            f"  {manifest_path}",
        ]
        if args.skip_bank:
            instructions.append("")
            instructions.append(
                "Bank rebuild was skipped; this package only contains patched XML and prepared WAV staging files."
            )
        write_text(out_dir / "package" / "INSTALL_README.txt", "\n".join(instructions) + "\n")

    print(f"Package manifest: {manifest_path}")
    print(f"XML totals      : {totals}")
    if args.skip_bank:
        print("Bank rebuild skipped.")
    return 0


def package_audio_dir(package_dir: Path) -> Path:
    if (package_dir / "media" / "audio").is_dir():
        return package_dir / "media" / "audio"
    if (package_dir / "package" / "media" / "audio").is_dir():
        return package_dir / "package" / "media" / "audio"
    if package_dir.name.lower() == "audio" and package_dir.is_dir():
        return package_dir
    if (package_dir / "media").is_dir():
        return package_dir
    if (package_dir / "package" / "media").is_dir():
        return package_dir / "package"
    die(f"Could not find package media/audio under {package_dir}")


def collect_package_files(
    package_audio: Path, require_files: bool = True
) -> List[Tuple[Path, Path]]:
    pairs: List[Tuple[Path, Path]] = []
    for xml in sorted(package_audio.glob("RadioInfo_*.xml")):
        pairs.append((xml, Path(xml.name)))
    bank_dir = package_audio / "FMODBanks"
    if bank_dir.is_dir():
        for bank in sorted(bank_dir.glob("*.assets.bank")):
            pairs.append((bank, Path("FMODBanks") / bank.name))
    if not pairs and require_files:
        die(f"No deployable RadioInfo_*.xml or FMODBanks/*.assets.bank found in {package_audio}")
    return pairs
