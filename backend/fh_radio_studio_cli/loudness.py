from __future__ import annotations

from statistics import median

from .audio import linear_resample
from .common import *
from .external_tools import find_executable
from .fsb5 import extract_embedded_fsb

LOUDNESS_ALGORITHM_VERSION = "fh-radio-studio-loudness-v1"
HEURISTIC_SAFE_MIN_LUFS = -28.0
HEURISTIC_SAFE_MAX_LUFS = -16.0
DEFAULT_TRUE_PEAK_CEILING_DBTP = -1.5
MIN_ACTIVE_DURATION_SEC = 1.0


def ensure_baseline_loudness_envelope(baseline_manifest: Optional[str]) -> Dict[str, object]:
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
    ):
        return existing

    measured, warnings = _try_measure_baseline_envelope(manifest_path, manifest, fingerprint)
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
    safe_min = float(envelope.get("safe_min_lufs", HEURISTIC_SAFE_MIN_LUFS))
    safe_max = float(envelope.get("safe_max_lufs", HEURISTIC_SAFE_MAX_LUFS))
    target = min(max(raw_target, safe_min), safe_max)
    if target == raw_target:
        reason = "custom_set_center"
    elif target == safe_max:
        reason = "custom_set_center_clamped_by_game_safe_max"
    else:
        reason = "custom_set_center_clamped_by_game_safe_min"

    return {
        "schema_version": 1,
        "kind": "custom_set_loudness_profile",
        "mode": "custom-set",
        "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
        "radio": radio,
        "track_count": len(analyses),
        "valid_track_count": len(valid),
        "raw_set_center_lufs": round(raw_target, 3),
        "target_lufs": round(target, 3),
        "target_reason": reason,
        "game_safe_range_lufs": [safe_min, safe_max],
        "true_peak_ceiling_dbtp": float(
            envelope.get("true_peak_ceiling_dbtp", DEFAULT_TRUE_PEAK_CEILING_DBTP)
        ),
        "envelope_source": envelope.get("source", "unknown"),
        "warnings": [],
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
    predicted_true_peak = input_true_peak + requested_gain
    peak_trim = min(0.0, ceiling - predicted_true_peak)
    applied_gain = requested_gain + peak_trim

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
        "input_integrated_lufs": round(input_lufs, 3),
        "input_true_peak_dbtp": round(input_true_peak, 3),
        "requested_gain_db": round(requested_gain, 3),
        "true_peak_trim_db": round(peak_trim, 3),
        "applied_gain_db": round(applied_gain, 3),
        "output_integrated_lufs": round(float(output_analysis["integrated_lufs"]), 3),
        "output_true_peak_dbtp": round(output_true_peak, 3),
        "target_delta_lu": round(float(output_analysis["integrated_lufs"]) - target_lufs, 3),
        "output_verified": bool(verify_output),
        "limited_by_true_peak": peak_trim < -0.001,
        "warnings": ["true_peak_ceiling_limited_gain"] if peak_trim < -0.001 else [],
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
        "safe_min_lufs": HEURISTIC_SAFE_MIN_LUFS,
        "safe_max_lufs": HEURISTIC_SAFE_MAX_LUFS,
        "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "warnings": warnings,
    }


def _existing_envelope(manifest: Dict[str, object]) -> Optional[Dict[str, object]]:
    derived_values = manifest.get("derived_values")
    if not isinstance(derived_values, dict):
        return None
    envelope = derived_values.get("loudness_envelope")
    return envelope if isinstance(envelope, dict) else None


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


def _try_measure_baseline_envelope(
    manifest_path: Path,
    manifest: Dict[str, object],
    fingerprint: str,
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

    analyses: List[Dict[str, object]] = []
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_root = Path(tmp_dir)
        for item in _baseline_bank_items(manifest):
            bank_path = _resolve_baseline_bank_path(manifest_path, item)
            if not bank_path or not bank_path.exists():
                warnings.append(f"baseline_bank_missing:{item.get('install_relative_path')}")
                continue
            try:
                fsb_path = tmp_root / f"{bank_path.stem}.fsb"
                info = extract_embedded_fsb(bank_path, fsb_path)
            except Exception as exc:
                warnings.append(f"extract_failed:{bank_path.name}:{type(exc).__name__}")
                continue
            for subsong in range(1, int(info.num_samples) + 1):
                wav_path = tmp_root / f"{bank_path.stem}_{subsong:04d}.wav"
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
                    warnings.append(f"decode_failed:{bank_path.name}:subsong{subsong}")
                    continue
                analysis = analyze_loudness_file(wav_path)
                if analysis.get("status") == "ok":
                    analyses.append(analysis)
                else:
                    warnings.append(f"analysis_failed:{bank_path.name}:subsong{subsong}")
                try:
                    wav_path.unlink()
                except OSError:
                    pass

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
    safe_min = max(-34.0, min(HEURISTIC_SAFE_MIN_LUFS, p10 - 4.0))
    safe_max = min(-14.0, max(HEURISTIC_SAFE_MAX_LUFS, p90 + 2.0))
    if safe_max - safe_min < 8.0:
        center = float(median(lufs_values))
        safe_min = center - 6.0
        safe_max = center + 2.0
    return (
        {
            "schema_version": 1,
            "kind": "baseline_loudness_envelope",
            "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
            "source": "measured",
            "source_fingerprint": fingerprint,
            "reference_track_count": len(lufs_values),
            "safe_min_lufs": round(float(safe_min), 3),
            "safe_max_lufs": round(float(safe_max), 3),
            "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "warnings": warnings,
        },
        warnings,
    )


def _resolve_baseline_bank_path(manifest_path: Path, item: Dict[str, object]) -> Optional[Path]:
    raw_backup = item.get("backup_path")
    if raw_backup:
        path = Path(str(raw_backup)).expanduser()
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


def _usable_loudness_analysis(analysis: Optional[Dict[str, object]]) -> bool:
    if not isinstance(analysis, dict):
        return False
    return (
        analysis.get("status") == "ok"
        and _is_finite_number(analysis.get("integrated_lufs"))
        and _is_finite_number(analysis.get("true_peak_dbtp"))
    )
