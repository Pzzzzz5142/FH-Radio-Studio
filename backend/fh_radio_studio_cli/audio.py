from __future__ import annotations

from .common import *

DJ_LITE_END_GAPS_SECONDS = {
    "StingerStart": 3.0,
    "DJStart": 2.0,
}


def linear_resample(data: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    if src_sr == dst_sr:
        return data

    old_len = data.shape[0]
    if old_len <= 1:
        return data

    new_len = int(round(old_len * dst_sr / src_sr))
    old_x = np.linspace(0.0, 1.0, old_len, endpoint=False, dtype=np.float64)
    new_x = np.linspace(0.0, 1.0, new_len, endpoint=False, dtype=np.float64)
    channels = [
        np.interp(new_x, old_x, data[:, channel]).astype(np.float32)
        for channel in range(data.shape[1])
    ]
    return np.stack(channels, axis=1)


def ffmpeg_convert_to_wav(src: Path, dst: Path, gain_db: float, ffmpeg: str) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(src),
        "-ac",
        "2",
        "-ar",
        str(TARGET_SAMPLE_RATE),
        "-sample_fmt",
        "s16",
        "-filter:a",
        f"volume={gain_db}dB",
        str(dst),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0 or not dst.exists():
        die(f"ffmpeg failed for {src}:\n{result.stderr[-2000:]}")


def prepare_audio_to_wav(
    src: Path, dst: Path, gain_db: float, ffmpeg: Optional[str] = None
) -> Tuple[Dict[str, object], Dict[str, object]]:
    try:
        data, src_sr = sf.read(str(src), dtype="float32", always_2d=True)
    except Exception as exc:
        if not ffmpeg:
            die(
                f"Could not read {src} with libsndfile ({exc}). Install/pass ffmpeg for this format."
            )
        ffmpeg_convert_to_wav(src, dst, gain_db, ffmpeg)
        data, out_sr = sf.read(str(dst), dtype="float32", always_2d=True)
        before = {
            "sample_rate": None,
            "channels": None,
            "samples": None,
            "peak_dbfs": None,
            "rms_dbfs": None,
            "decoder": "ffmpeg",
        }
        after = {
            "sample_rate": out_sr,
            "channels": int(data.shape[1]),
            "samples": int(data.shape[0]),
            "peak_dbfs": peak_dbfs(data),
            "rms_dbfs": rms_dbfs(data),
            "decoder": "ffmpeg",
        }
        return before, after

    before = {
        "sample_rate": src_sr,
        "channels": int(data.shape[1]),
        "samples": int(data.shape[0]),
        "peak_dbfs": peak_dbfs(data),
        "rms_dbfs": rms_dbfs(data),
        "decoder": "soundfile",
    }

    if src_sr != TARGET_SAMPLE_RATE:
        data = linear_resample(data, src_sr, TARGET_SAMPLE_RATE)
    sr = TARGET_SAMPLE_RATE
    out_data = np.clip(data * db_to_linear(gain_db), -1.0, 1.0)
    dst.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(dst), out_data, sr, subtype="PCM_16")

    after = {
        "sample_rate": sr,
        "channels": int(out_data.shape[1]),
        "samples": int(out_data.shape[0]),
        "peak_dbfs": peak_dbfs(out_data),
        "rms_dbfs": rms_dbfs(out_data),
        "decoder": "soundfile",
    }
    return before, after


def build_markers(
    args: argparse.Namespace, timing: Dict[str, int], total_samples: int, sr: int
) -> Dict[str, int]:
    markers = dict(DEFAULT_MARKERS)
    markers.update(timing)
    markers["End"] = total_samples - 1
    apply_dj_lite_markers(markers, total_samples, sr)

    overrides = {
        "TrackDrop": seconds_to_samples(getattr(args, "track_drop_sec", None), sr),
        "PostDrop": seconds_to_samples(getattr(args, "post_drop_sec", None), sr),
        "TrackLoopStart": seconds_to_samples(getattr(args, "track_loop_start_sec", None), sr),
        "TrackLoopEnd": seconds_to_samples(getattr(args, "track_loop_end_sec", None), sr),
        "PostRaceLoopStart": seconds_to_samples(getattr(args, "post_loop_start_sec", None), sr),
        "PostRaceLoopEnd": seconds_to_samples(getattr(args, "post_loop_end_sec", None), sr),
    }
    for name, value in overrides.items():
        if value is not None:
            markers[name] = value

    for name, value in list(markers.items()):
        if value >= 0:
            markers[name] = int(max(0, min(value, total_samples - 1)))
        else:
            markers[name] = int(value)
    return markers


def apply_dj_lite_markers(markers: Dict[str, int], total_samples: int, sr: int) -> None:
    for name, gap_seconds in DJ_LITE_END_GAPS_SECONDS.items():
        if markers.get(name, -1) >= 0:
            continue
        markers[name] = end_anchored_marker(total_samples, sr, gap_seconds)


def end_anchored_marker(total_samples: int, sr: int, gap_seconds: float) -> int:
    if total_samples <= 0:
        return -1
    if sr <= 0:
        sr = TARGET_SAMPLE_RATE
    gap = int(round(float(gap_seconds) * sr))
    if gap <= 0:
        return max(0, total_samples - 1)
    if gap >= total_samples:
        gap = max(1, total_samples // 2)
    return max(0, min(total_samples - gap, total_samples - 1))


def load_timing_overrides(path: Optional[str]) -> Dict[str, Dict[str, object]]:
    if not path:
        return {}
    manifest_path = Path(path).expanduser()
    if not manifest_path.exists():
        die(f"Timing manifest not found: {manifest_path}")
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"Timing manifest is not valid JSON: {exc}")
    tracks = payload.get("tracks") if isinstance(payload, dict) else None
    if not isinstance(tracks, list):
        die("Timing manifest must contain a tracks array")
    out: Dict[str, Dict[str, object]] = {}
    for item in tracks:
        if not isinstance(item, dict):
            continue
        source = item.get("source")
        if not source:
            continue
        out[path_key(Path(str(source)).expanduser())] = item
    return out


def timing_override_for(
    overrides: Dict[str, Dict[str, object]], source: Path
) -> Optional[Dict[str, object]]:
    return overrides.get(path_key(source))


def marker_seconds_from_override(
    override: Optional[Dict[str, object]], marker: str
) -> Optional[float]:
    if not override:
        return None
    markers = override.get("markers_sec")
    if not isinstance(markers, dict):
        return None
    value = markers.get(marker)
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def bpm_from_override(override: Optional[Dict[str, object]], fallback: str) -> str:
    if not override:
        return fallback
    value = override.get("bpm")
    if value is None:
        return fallback
    try:
        bpm = float(value)
    except (TypeError, ValueError):
        return fallback
    return str(round(bpm, 3)).rstrip("0").rstrip(".")


def read_audio_for_analysis(src: Path, ffmpeg: Optional[str] = None) -> Tuple[np.ndarray, int, str]:
    try:
        data, sr = sf.read(str(src), dtype="float32", always_2d=True)
        return data, sr, "soundfile"
    except Exception as exc:
        if not ffmpeg:
            die(
                f"Could not read {src} with libsndfile ({exc}). Install/pass ffmpeg for this format."
            )
        with tempfile.TemporaryDirectory() as tmp_dir:
            wav = Path(tmp_dir) / "analysis.wav"
            ffmpeg_convert_to_wav(src, wav, gain_db=0.0, ffmpeg=ffmpeg)
            data, sr = sf.read(str(wav), dtype="float32", always_2d=True)
            return data, sr, "ffmpeg"


def waveform_summary(data: np.ndarray, bins: int) -> Dict[str, object]:
    mono = data.mean(axis=1) if data.ndim > 1 else data
    total = len(mono)
    bins = max(16, min(2048, bins))
    values: List[Dict[str, float]] = []
    if total == 0:
        return {"bins": [], "max_peak": 0.0}
    max_peak = float(np.max(np.abs(mono)) + 1e-9)
    for index in range(bins):
        start = int(index * total / bins)
        end = int((index + 1) * total / bins)
        chunk = mono[start : max(end, start + 1)]
        peak = float(np.max(np.abs(chunk))) if len(chunk) else 0.0
        rms = float(np.sqrt(np.mean(chunk**2))) if len(chunk) else 0.0
        values.append(
            {
                "peak": peak,
                "rms": rms,
                "norm_peak": min(1.0, peak / max_peak),
                "norm_rms": min(1.0, rms / max_peak),
            }
        )
    return {"bins": values, "max_peak": max_peak}
