from __future__ import annotations

from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, wait
from statistics import median

from .audio import linear_resample
from .common import *
from .external_tools import find_executable
from .fsb5 import extract_embedded_fsb
from .project_refs import ProjectRefError, is_project_ref, resolve_project_ref

LOUDNESS_ALGORITHM_VERSION = "fh-radio-studio-loudness-v2"
HEURISTIC_SAFE_MIN_LUFS = -28.0
HEURISTIC_SAFE_MAX_LUFS = -16.0
HEURISTIC_REFERENCE_MEDIAN_LUFS = -24.0
DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU = 3.0
MIN_CUSTOM_LOUDNESS_OFFSET_LU = 0.0
MAX_CUSTOM_LOUDNESS_OFFSET_LU = 6.0
DEFAULT_TRUE_PEAK_CEILING_DBTP = -1.5
DEFAULT_MAX_POSITIVE_GAIN_DB = 8.0
MIN_ACTIVE_DURATION_SEC = 1.0


def normalize_custom_loudness_offset_lu(value: object) -> float:
    offset = _finite_float(value, None)
    if offset is None:
        die("Loudness offset must be a finite LU value.")
    if offset < MIN_CUSTOM_LOUDNESS_OFFSET_LU or offset > MAX_CUSTOM_LOUDNESS_OFFSET_LU:
        die(
            "Loudness offset must be between "
            f"+{MIN_CUSTOM_LOUDNESS_OFFSET_LU:g} and +{MAX_CUSTOM_LOUDNESS_OFFSET_LU:g} LU."
        )
    return float(offset)


def ensure_baseline_loudness_envelope(
    baseline_manifest: Optional[str],
    *,
    loudness_jobs: int = 0,
) -> Dict[str, object]:
    if not baseline_manifest:
        return _heuristic_envelope(["no_baseline_manifest"])

    manifest_path = Path(baseline_manifest).expanduser()
    if not manifest_path.exists():
        return _heuristic_envelope(["baseline_manifest_missing"])

    manifest = load_manifest(manifest_path)
    fingerprint = _baseline_loudness_fingerprint(manifest)
    existing = _existing_envelope(manifest)
    if (
        existing
        and existing.get("algorithm_version") == LOUDNESS_ALGORITHM_VERSION
        and existing.get("source_fingerprint") == fingerprint
        and _complete_loudness_envelope(existing)
    ):
        return existing

    measured, warnings = _try_measure_baseline_envelope(
        manifest_path,
        manifest,
        fingerprint,
        loudness_jobs=loudness_jobs,
    )
    envelope = measured if measured is not None else _heuristic_envelope(warnings)
    if measured is None:
        envelope["source_fingerprint"] = fingerprint

    derived_values = manifest.get("derived_values")
    if not isinstance(derived_values, dict):
        derived_values = {}
    derived_values["loudness_envelope"] = envelope
    manifest["derived_values"] = derived_values
    write_json(manifest_path, manifest)
    return envelope


def loudness_worker_count(requested_jobs: object, task_count: int) -> int:
    if task_count <= 1:
        return 1
    requested = int(requested_jobs or 0)
    if requested > 0:
        return max(1, min(requested, task_count))
    cpu_count = os.cpu_count() or 1
    auto_workers = max(2, cpu_count // 2)
    return max(1, min(auto_workers, task_count))


def analyze_loudness_file(src: Path, *, ffmpeg: Optional[str] = None) -> Dict[str, object]:
    data, sample_rate, decoder = _read_audio(src, ffmpeg=ffmpeg)
    if sample_rate != TARGET_SAMPLE_RATE:
        data = linear_resample(data, sample_rate, TARGET_SAMPLE_RATE)
        sample_rate = TARGET_SAMPLE_RATE
    data = _to_stereo(data)
    analysis = analyze_loudness_data(data, sample_rate)
    analysis.update(
        {
            "source": str(src.resolve()),
            "decoder": decoder,
            "sample_rate": sample_rate,
            "channels": int(data.shape[1]) if data.ndim > 1 else 1,
            "samples": int(data.shape[0]),
            "peak_dbfs": peak_dbfs(data),
            "rms_dbfs": rms_dbfs(data),
        }
    )
    return analysis


def analyze_loudness_data(data: np.ndarray, sample_rate: int) -> Dict[str, object]:
    data = _to_stereo(data.astype(np.float32, copy=False))
    warnings: List[str] = []
    duration_sec = float(data.shape[0] / sample_rate) if sample_rate > 0 else 0.0
    active_duration, silence_ratio = _active_duration(data, sample_rate)
    if duration_sec <= 0:
        return _failed_analysis("empty_audio", warnings)
    if active_duration < MIN_ACTIVE_DURATION_SEC:
        return _failed_analysis("not_enough_active_audio", warnings)

    try:
        import pyloudnorm as pyln

        meter = pyln.Meter(sample_rate)
        integrated_lufs = float(meter.integrated_loudness(data))
    except Exception as exc:
        return _failed_analysis(f"lufs_measurement_failed:{type(exc).__name__}", warnings)

    if not np.isfinite(integrated_lufs):
        return _failed_analysis("non_finite_lufs", warnings)

    true_peak = true_peak_dbtp(data, sample_rate)
    return {
        "status": "ok",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "integrated_lufs": integrated_lufs,
        "true_peak_dbtp": true_peak,
        "sample_peak_dbfs": peak_dbfs(data),
        "rms_dbfs": rms_dbfs(data),
        "lra": None,
        "duration_sec": duration_sec,
        "active_duration_sec": active_duration,
        "silence_ratio": silence_ratio,
        "warnings": warnings,
    }


def build_custom_set_loudness_profile(
    analyses: List[Dict[str, object]],
    envelope: Dict[str, object],
    *,
    radio: Optional[int] = None,
    target_offset_lu: object = 0.0,
) -> Dict[str, object]:
    valid = [
        float(item["integrated_lufs"])
        for item in analyses
        if item.get("status") == "ok" and _is_finite_number(item.get("integrated_lufs"))
    ]
    if not valid:
        die("Could not measure loudness for any assigned music track.")

    ordered = sorted(valid)
    if len(ordered) >= 10:
        trim = max(1, int(len(ordered) * 0.1))
        robust_values = ordered[trim:-trim] or ordered
    else:
        robust_values = ordered

    raw_target = float(median(robust_values))
    safe_min = _finite_float(envelope.get("safe_min_lufs"), HEURISTIC_SAFE_MIN_LUFS)
    safe_max = _finite_float(envelope.get("safe_max_lufs"), HEURISTIC_SAFE_MAX_LUFS)
    if safe_max < safe_min:
        safe_min, safe_max = HEURISTIC_SAFE_MIN_LUFS, HEURISTIC_SAFE_MAX_LUFS
    reference_median = _finite_float(envelope.get("reference_median_lufs"), None)
    offset_lu = normalize_custom_loudness_offset_lu(target_offset_lu)
    warnings: List[str] = []
    if reference_median is None:
        base_target = raw_target
        reason_prefix = "custom_set_center"
        target_basis = "custom-set-center"
        warnings.append("reference_median_lufs_missing")
    else:
        base_target = reference_median
        reason_prefix = "baseline_reference_median"
        target_basis = "baseline-reference-median"
    reference_target = base_target + offset_lu
    if abs(offset_lu) > 0.001:
        reason_prefix = f"{reason_prefix}_plus_offset"
        target_basis = f"{target_basis}-plus-offset"

    target = min(max(reference_target, safe_min), safe_max)
    if target == reference_target:
        reason = reason_prefix
    elif target == safe_max:
        reason = f"{reason_prefix}_clamped_by_game_safe_max"
    else:
        reason = f"{reason_prefix}_clamped_by_game_safe_min"

    return {
        "schema_version": 1,
        "kind": "custom_set_loudness_profile",
        "mode": "custom-set",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "radio": radio,
        "track_count": len(analyses),
        "valid_track_count": len(valid),
        "raw_set_center_lufs": round(raw_target, 3),
        "reference_median_lufs": (
            round(reference_median, 3) if reference_median is not None else None
        ),
        "base_target_lufs": round(base_target, 3),
        "target_offset_lu": round(offset_lu, 3),
        "unclamped_target_lufs": round(reference_target, 3),
        "target_lufs": round(target, 3),
        "target_basis": target_basis,
        "target_reason": reason,
        "game_safe_range_lufs": [safe_min, safe_max],
        "true_peak_ceiling_dbtp": float(
            envelope.get("true_peak_ceiling_dbtp", DEFAULT_TRUE_PEAK_CEILING_DBTP)
        ),
        "max_positive_gain_db": _finite_float(
            envelope.get("max_positive_gain_db"), DEFAULT_MAX_POSITIVE_GAIN_DB
        ),
        "envelope_source": envelope.get("source", "unknown"),
        "warnings": warnings,
    }


def prepare_loudness_matched_audio(
    src: Path,
    dst: Path,
    profile: Dict[str, object],
    *,
    ffmpeg: Optional[str] = None,
    input_analysis: Optional[Dict[str, object]] = None,
    verify_output: bool = True,
) -> Tuple[Dict[str, object], Dict[str, object], Dict[str, object]]:
    data, source_sample_rate, decoder = _read_audio(src, ffmpeg=ffmpeg)
    data = _to_stereo(data)
    before = {
        "sample_rate": source_sample_rate,
        "channels": int(data.shape[1]),
        "samples": int(data.shape[0]),
        "peak_dbfs": peak_dbfs(data),
        "rms_dbfs": rms_dbfs(data),
        "decoder": decoder,
    }
    if source_sample_rate != TARGET_SAMPLE_RATE:
        data = linear_resample(data, source_sample_rate, TARGET_SAMPLE_RATE)
    sample_rate = TARGET_SAMPLE_RATE

    if not _usable_loudness_analysis(input_analysis):
        input_analysis = analyze_loudness_data(data, sample_rate)
    if input_analysis.get("status") != "ok":
        die(f"Could not measure loudness for {src}: {input_analysis.get('error')}")

    target_lufs = float(profile["target_lufs"])
    ceiling = float(profile["true_peak_ceiling_dbtp"])
    input_lufs = float(input_analysis["integrated_lufs"])
    input_true_peak = float(input_analysis["true_peak_dbtp"])
    requested_gain = target_lufs - input_lufs
    max_positive_gain = _finite_float(
        profile.get("max_positive_gain_db"), DEFAULT_MAX_POSITIVE_GAIN_DB
    )
    positive_gain_trim = min(0.0, max_positive_gain - requested_gain)
    gain_after_boost_cap = requested_gain + positive_gain_trim
    predicted_true_peak = input_true_peak + gain_after_boost_cap
    peak_trim = min(0.0, ceiling - predicted_true_peak)
    applied_gain = gain_after_boost_cap + peak_trim

    out_data = np.clip(data * db_to_linear(applied_gain), -1.0, 1.0).astype(np.float32)
    if verify_output:
        output_analysis = analyze_loudness_data(out_data, sample_rate)
        if output_analysis.get("status") != "ok":
            die(f"Could not verify loudness output for {src}: {output_analysis.get('error')}")
        output_lufs = float(output_analysis["integrated_lufs"])
        output_true_peak = float(output_analysis["true_peak_dbtp"])
    else:
        output_lufs = input_lufs + applied_gain
        output_true_peak = input_true_peak + applied_gain
        output_analysis = {
            "integrated_lufs": output_lufs,
            "true_peak_dbtp": output_true_peak,
        }
    if output_true_peak > ceiling + 0.1:
        die(
            f"Loudness output for {src} exceeds true peak ceiling: "
            f"{output_true_peak:.2f} dBTP > {ceiling:.2f} dBTP"
        )

    dst.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(dst), out_data, sample_rate, subtype="PCM_16")

    after = {
        "sample_rate": sample_rate,
        "channels": int(out_data.shape[1]),
        "samples": int(out_data.shape[0]),
        "peak_dbfs": peak_dbfs(out_data),
        "rms_dbfs": rms_dbfs(out_data),
        "decoder": decoder,
    }
    loudness = {
        "schema_version": 1,
        "mode": "custom-set",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "target_lufs": round(target_lufs, 3),
        "true_peak_ceiling_dbtp": round(ceiling, 3),
        "max_positive_gain_db": round(max_positive_gain, 3),
        "input_integrated_lufs": round(input_lufs, 3),
        "input_true_peak_dbtp": round(input_true_peak, 3),
        "requested_gain_db": round(requested_gain, 3),
        "positive_gain_trim_db": round(positive_gain_trim, 3),
        "true_peak_trim_db": round(peak_trim, 3),
        "applied_gain_db": round(applied_gain, 3),
        "output_integrated_lufs": round(float(output_analysis["integrated_lufs"]), 3),
        "output_true_peak_dbtp": round(output_true_peak, 3),
        "target_delta_lu": round(float(output_analysis["integrated_lufs"]) - target_lufs, 3),
        "output_verified": bool(verify_output),
        "limited_by_max_positive_gain": positive_gain_trim < -0.001,
        "limited_by_true_peak": peak_trim < -0.001,
        "warnings": (
            (["max_positive_gain_limited_boost"] if positive_gain_trim < -0.001 else [])
            + (["true_peak_ceiling_limited_gain"] if peak_trim < -0.001 else [])
        ),
    }
    return before, after, loudness


def true_peak_dbtp(data: np.ndarray, sample_rate: int, *, oversample: int = 4) -> float:
    data = _to_stereo(data)
    if data.size == 0:
        return float("-inf")
    try:
        from scipy.signal import resample_poly

        upsampled = resample_poly(data, oversample, 1, axis=0)
        peak = float(np.max(np.abs(upsampled)))
    except Exception:
        peak = float(np.max(np.abs(data)))
    return float(20.0 * np.log10(peak + 1e-12))


def _read_audio(src: Path, *, ffmpeg: Optional[str]) -> Tuple[np.ndarray, int, str]:
    try:
        data, sample_rate = sf.read(str(src), dtype="float32", always_2d=True)
        return data, int(sample_rate), "soundfile"
    except Exception as exc:
        if not ffmpeg:
            die(
                f"Could not read {src} with libsndfile ({exc}). Install/pass ffmpeg for this format."
            )
        from .audio import ffmpeg_convert_to_wav

        with tempfile.TemporaryDirectory() as tmp_dir:
            wav = Path(tmp_dir) / "loudness-source.wav"
            ffmpeg_convert_to_wav(src, wav, gain_db=0.0, ffmpeg=ffmpeg)
            data, sample_rate = sf.read(str(wav), dtype="float32", always_2d=True)
            return data, int(sample_rate), "ffmpeg"


def _to_stereo(data: np.ndarray) -> np.ndarray:
    if data.ndim == 1:
        data = data[:, np.newaxis]
    if data.shape[1] == 1:
        return np.repeat(data, 2, axis=1)
    if data.shape[1] == 2:
        return data
    return data[:, :2]


def _active_duration(data: np.ndarray, sample_rate: int) -> Tuple[float, float]:
    mono = data.mean(axis=1) if data.ndim > 1 else data
    if mono.size == 0 or sample_rate <= 0:
        return 0.0, 1.0
    frame = max(1, int(round(sample_rate * 0.4)))
    frame_count = max(1, int(np.ceil(mono.size / frame)))
    active = 0
    for index in range(frame_count):
        chunk = mono[index * frame : min(mono.size, (index + 1) * frame)]
        if chunk.size == 0:
            continue
        rms = float(np.sqrt(np.mean(chunk * chunk)) + 1e-12)
        if 20.0 * np.log10(rms) > -70.0:
            active += 1
    active_duration = active * frame / sample_rate
    silence_ratio = 1.0 - (active / frame_count)
    return float(active_duration), float(max(0.0, min(1.0, silence_ratio)))


def _failed_analysis(error: str, warnings: List[str]) -> Dict[str, object]:
    return {
        "status": "error",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "error": error,
        "integrated_lufs": None,
        "true_peak_dbtp": None,
        "sample_peak_dbfs": None,
        "rms_dbfs": None,
        "lra": None,
        "duration_sec": 0.0,
        "active_duration_sec": 0.0,
        "silence_ratio": 1.0,
        "warnings": warnings,
    }


def _heuristic_envelope(warnings: List[str]) -> Dict[str, object]:
    return {
        "schema_version": 1,
        "kind": "baseline_loudness_envelope",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "source": "heuristic",
        "reference_track_count": 0,
        "reference_min_lufs": HEURISTIC_SAFE_MIN_LUFS,
        "reference_median_lufs": HEURISTIC_REFERENCE_MEDIAN_LUFS,
        "reference_max_lufs": HEURISTIC_SAFE_MAX_LUFS,
        "safe_min_lufs": HEURISTIC_SAFE_MIN_LUFS,
        "safe_max_lufs": HEURISTIC_SAFE_MAX_LUFS,
        "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
        "max_positive_gain_db": DEFAULT_MAX_POSITIVE_GAIN_DB,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "warnings": warnings,
    }


def _existing_envelope(manifest: Dict[str, object]) -> Optional[Dict[str, object]]:
    derived_values = manifest.get("derived_values")
    if not isinstance(derived_values, dict):
        return None
    envelope = derived_values.get("loudness_envelope")
    return envelope if isinstance(envelope, dict) else None


def _complete_loudness_envelope(envelope: Dict[str, object]) -> bool:
    required_numbers = (
        "reference_min_lufs",
        "reference_median_lufs",
        "reference_max_lufs",
        "safe_min_lufs",
        "safe_max_lufs",
        "true_peak_ceiling_dbtp",
        "max_positive_gain_db",
    )
    return all(_is_finite_number(envelope.get(key)) for key in required_numbers)


def _baseline_loudness_fingerprint(manifest: Dict[str, object]) -> str:
    digest = hashlib.sha256()
    digest.update(LOUDNESS_ALGORITHM_VERSION.encode("utf-8"))
    for item in _baseline_bank_items(manifest):
        install_rel = str(item.get("install_relative_path") or item.get("relative_path") or "")
        md5 = str(item.get("md5") or "")
        digest.update(install_rel.encode("utf-8", errors="replace"))
        digest.update(b"\0")
        digest.update(md5.encode("utf-8", errors="replace"))
        digest.update(b"\0")
    return digest.hexdigest()


def _baseline_bank_items(manifest: Dict[str, object]) -> List[Dict[str, object]]:
    return [
        item
        for item in list(manifest.get("files", []))
        if isinstance(item, dict) and item.get("scope") == "radio_bank"
    ]


def baseline_loudness_bank_count(manifest: Dict[str, object]) -> int:
    """原始 bank 解码任务数；用于在进度计划里预估基线响度统计的并行进程数。"""
    return len(_baseline_bank_items(manifest))


def _decode_baseline_bank_worker(
    vgmstream: str,
    bank_path_text: str,
    bank_name: str,
    bank_index: int,
    out_root_text: str,
) -> Tuple[str, List[Tuple[str, int, str]], List[str]]:
    decoded: List[Tuple[str, int, str]] = []
    warnings: List[str] = []
    out_root = Path(out_root_text)
    bank_path = Path(bank_path_text)
    bank_dir = out_root / f"{bank_index:04d}_{sanitize_token(bank_path.stem, 'bank')}"
    bank_dir.mkdir(parents=True, exist_ok=True)
    fsb_path = bank_dir / f"{bank_path.stem}.fsb"
    try:
        info = extract_embedded_fsb(bank_path, fsb_path)
    except Exception as exc:
        return bank_name, [], [f"extract_failed:{bank_name}:{type(exc).__name__}"]

    for subsong in range(1, int(info.num_samples) + 1):
        wav_path = bank_dir / f"{bank_path.stem}_{subsong:04d}.wav"
        cmd = [
            vgmstream,
            "-i",
            "-s",
            str(subsong),
            "-o",
            str(wav_path),
            str(fsb_path),
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode != 0 or not wav_path.exists():
            warnings.append(f"decode_failed:{bank_name}:subsong{subsong}")
            continue
        decoded.append((bank_name, subsong, str(wav_path)))
    return bank_name, decoded, warnings


def _analyze_baseline_wav_worker(
    bank_name: str,
    subsong: int,
    wav_path_text: str,
) -> Tuple[str, int, Optional[Dict[str, object]], Optional[str]]:
    analysis = analyze_loudness_file(Path(wav_path_text))
    if analysis.get("status") != "ok":
        return bank_name, subsong, None, f"analysis_failed:{bank_name}:subsong{subsong}"
    return bank_name, subsong, analysis, None


def _measure_baseline_banks(
    tasks: List[Tuple[str, str, str, int, str]],
    *,
    loudness_jobs: int,
) -> Tuple[List[Dict[str, object]], List[str]]:
    if not tasks:
        return [], []

    worker_count = loudness_worker_count(loudness_jobs, len(tasks))
    print(
        "  Baseline loudness pipeline: "
        f"decoding/analyzing {len(tasks)} bank(s) with {worker_count} process(es)."
    )

    analyses: List[Dict[str, object]] = []
    warnings: List[str] = []

    def record_analysis(
        bank_name: str,
        subsong: int,
        analysis: Optional[Dict[str, object]],
        warning: Optional[str],
    ) -> None:
        if warning:
            warnings.append(warning)
            return
        if analysis is None:
            warnings.append(f"analysis_failed:{bank_name}:subsong{subsong}")
            return
        analyses.append(analysis)

    if worker_count <= 1:
        decoded: List[Tuple[str, int, str]] = []
        for task in tasks:
            try:
                _bank_name, bank_decoded, bank_warnings = _decode_baseline_bank_worker(*task)
            except Exception as exc:
                warnings.append(f"bank_decode_failed:{task[2]}:{type(exc).__name__}")
                continue
            decoded.extend(bank_decoded)
            warnings.extend(bank_warnings)
        for wav_task in decoded:
            try:
                bank_name, subsong, analysis, warning = _analyze_baseline_wav_worker(*wav_task)
            except Exception as exc:
                bank_name, subsong = wav_task[0], wav_task[1]
                warnings.append(
                    f"analysis_failed:{bank_name}:subsong{subsong}:{type(exc).__name__}"
                )
                continue
            record_analysis(bank_name, subsong, analysis, warning)
        return analyses, warnings

    with ProcessPoolExecutor(max_workers=worker_count) as pool:
        pending: Dict[object, Tuple[str, object]] = {}
        for task in tasks:
            pending[pool.submit(_decode_baseline_bank_worker, *task)] = ("decode", task[2])

        while pending:
            done, _pending = wait(pending, return_when=FIRST_COMPLETED)
            for future in done:
                kind, meta = pending.pop(future)
                if kind == "decode":
                    bank_name = str(meta)
                    try:
                        _result_bank, bank_decoded, bank_warnings = future.result()
                    except Exception as exc:
                        warnings.append(f"bank_decode_failed:{bank_name}:{type(exc).__name__}")
                        bank_decoded = []
                        bank_warnings = []
                    warnings.extend(bank_warnings)
                    for wav_task in bank_decoded:
                        pending[pool.submit(_analyze_baseline_wav_worker, *wav_task)] = (
                            "analyze",
                            (wav_task[0], wav_task[1]),
                        )
                else:
                    bank_name, subsong = meta  # type: ignore[misc]
                    try:
                        result_bank, result_subsong, analysis, warning = future.result()
                    except Exception as exc:
                        warnings.append(
                            f"analysis_failed:{bank_name}:subsong{subsong}:{type(exc).__name__}"
                        )
                        continue
                    record_analysis(result_bank, result_subsong, analysis, warning)
    return analyses, warnings


def _try_measure_baseline_envelope(
    manifest_path: Path,
    manifest: Dict[str, object],
    fingerprint: str,
    *,
    loudness_jobs: int = 0,
) -> Tuple[Optional[Dict[str, object]], List[str]]:
    warnings: List[str] = []
    try:
        vgmstream = find_executable(None, "vgmstream-cli")
    except CliError as exc:
        vgmstream = None
        warnings.append(f"vgmstream_lookup_failed:{exc}")
    if not vgmstream:
        warnings.append("vgmstream_missing")
        return None, warnings

    with tempfile.TemporaryDirectory() as tmp_dir:
        tasks: List[Tuple[str, str, str, int, str]] = []
        for bank_index, item in enumerate(_baseline_bank_items(manifest)):
            bank_path = _resolve_baseline_bank_path(manifest_path, item)
            if not bank_path or not bank_path.exists():
                warnings.append(f"baseline_bank_missing:{item.get('install_relative_path')}")
                continue
            tasks.append((vgmstream, str(bank_path), bank_path.name, bank_index, tmp_dir))
        analyses, task_warnings = _measure_baseline_banks(
            tasks,
            loudness_jobs=loudness_jobs,
        )
        warnings.extend(task_warnings)

    lufs_values = sorted(
        float(item["integrated_lufs"])
        for item in analyses
        if item.get("status") == "ok" and _is_finite_number(item.get("integrated_lufs"))
    )
    if len(lufs_values) < 3:
        warnings.append("not_enough_reference_tracks")
        return None, warnings

    p10 = _percentile(lufs_values, 10)
    p90 = _percentile(lufs_values, 90)
    reference_median = float(median(lufs_values))
    safe_min = max(-34.0, min(HEURISTIC_SAFE_MIN_LUFS, p10 - 4.0))
    safe_max = min(-14.0, max(HEURISTIC_SAFE_MAX_LUFS, p90 + 2.0))
    if safe_max - safe_min < 8.0:
        safe_min = reference_median - 6.0
        safe_max = reference_median + 2.0
    return (
        {
            "schema_version": 1,
            "kind": "baseline_loudness_envelope",
            "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
            "source": "measured",
            "source_fingerprint": fingerprint,
            "reference_track_count": len(lufs_values),
            "reference_min_lufs": round(float(lufs_values[0]), 3),
            "reference_p10_lufs": round(float(p10), 3),
            "reference_median_lufs": round(reference_median, 3),
            "reference_p90_lufs": round(float(p90), 3),
            "reference_max_lufs": round(float(lufs_values[-1]), 3),
            "safe_min_lufs": round(float(safe_min), 3),
            "safe_max_lufs": round(float(safe_max), 3),
            "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
            "max_positive_gain_db": DEFAULT_MAX_POSITIVE_GAIN_DB,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "warnings": warnings,
        },
        warnings,
    )


def _project_root_from_baseline_dir(baseline_dir: Path) -> Optional[Path]:
    if baseline_dir.parent.name == "backups":
        return baseline_dir.parent.parent
    return None


def _resolve_baseline_bank_path(manifest_path: Path, item: Dict[str, object]) -> Optional[Path]:
    raw_backup = item.get("backup_path")
    if raw_backup:
        raw_text = str(raw_backup)
        if is_project_ref(raw_text):
            project_dir = _project_root_from_baseline_dir(manifest_path.parent)
            if project_dir is not None:
                try:
                    path = resolve_project_ref(project_dir, raw_text)
                except ProjectRefError:
                    path = None
                if path and path.exists():
                    return path
        path = Path(raw_text).expanduser()
        if path.exists():
            return path
    install_rel = str(item.get("install_relative_path") or "").replace("\\", "/").strip("/")
    if install_rel:
        return manifest_path.parent / Path(*install_rel.split("/"))
    rel = str(item.get("relative_path") or "").replace("\\", "/").strip("/")
    if rel:
        return manifest_path.parent / "media" / "audio" / Path(*rel.split("/"))
    return None


def _percentile(values: List[float], percentile: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return float(values[0])
    pos = (len(values) - 1) * percentile / 100.0
    lo = int(np.floor(pos))
    hi = int(np.ceil(pos))
    if lo == hi:
        return float(values[lo])
    return float(values[lo] + (values[hi] - values[lo]) * (pos - lo))


def _is_finite_number(value: object) -> bool:
    try:
        return bool(np.isfinite(float(value)))
    except (TypeError, ValueError):
        return False


def _finite_float(value: object, fallback: Optional[float]) -> Optional[float]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return fallback
    return number if np.isfinite(number) else fallback


def _usable_loudness_analysis(analysis: Optional[Dict[str, object]]) -> bool:
    if not isinstance(analysis, dict):
        return False
    return (
        analysis.get("status") == "ok"
        and _is_finite_number(analysis.get("integrated_lufs"))
        and _is_finite_number(analysis.get("true_peak_dbtp"))
    )
