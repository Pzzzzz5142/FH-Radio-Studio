from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from time import perf_counter
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from ..schema import ProviderStatus
from .diagnostics import ProviderTimer, torch_model_runtime
from .runtime import cache_has_any, executable_path, import_probe, package_version, torch_device


def check(model_dir: Path, enabled: bool) -> ProviderStatus:
    if not enabled:
        return ProviderStatus(name="beat_this", status="disabled")
    python_api, import_error = import_probe("beat_this.inference")
    cli_path = executable_path("beat_this")
    version = package_version("beat-this", "beat_this") or "unknown"
    if not python_api and version != "unknown":
        return ProviderStatus(
            name="beat_this",
            status="error",
            version=version,
            device=torch_device(),
            warnings=[
                "Beat This is installed but cannot be imported by the current Python runtime. "
                f"{import_error}. Use a uv-managed Python 3.10+ environment for this provider."
            ],
        )
    checkpoint_ready = cache_has_any(
        model_dir / "beat_this",
        ("*.ckpt", "*.pt", "*.pth", "final*", "**/*.ckpt", "**/*.pt", "**/*.pth"),
    )
    if python_api or cli_path:
        warnings = []
        if not checkpoint_ready:
            warnings.append(
                f"Beat This runtime is installed, but no checkpoint marker was found under {model_dir / 'beat_this'}. "
                "Warm or place the final0 checkpoint there before relying on offline analysis."
            )
        return ProviderStatus(
            name="beat_this",
            status="ready" if checkpoint_ready else "partial",
            version=version,
            device=torch_device(),
            warnings=warnings,
        )
    return ProviderStatus(
        name="beat_this",
        status="missing",
        version="beat-this package not found",
        warnings=[
            "Beat This runtime is not installed. Expected Python package `beat-this` "
            f"or executable `beat_this`; baseline beat grid is being used. Model Dir: {model_dir}"
        ],
    )


def analyze(
    source: Path,
    *,
    model_dir: Path,
    max_beats: int,
) -> Dict[str, object]:
    timer = ProviderTimer()
    with timer.stage("check"):
        status = check(model_dir, True)
    if status.status != "ready":
        status.runtime_ms = timer.elapsed_ms()
        return {
            "status": status,
            "beats": [],
            "downbeats": [],
            "bpm": None,
            "confidence": 0.0,
            "runtime": {"backend": None, "requested_device": torch_device()},
            "timings": timer.snapshot(total_ms=status.runtime_ms),
            "warnings": list(status.warnings),
        }
    try:
        beats, downbeats, runtime = _run_python_api(
            source,
            model_dir,
            timer,
        )
        backend = "python_api"
    except Exception as python_exc:
        try:
            beats, downbeats, runtime = _run_cli(source, model_dir, timer)
            backend = "cli"
        except Exception as cli_exc:
            status.status = "error"
            status.runtime_ms = timer.elapsed_ms()
            status.warnings = [
                "Beat This failed; baseline beat grid is being used. "
                f"Python API error: {python_exc}; CLI error: {cli_exc}"
            ]
            return {
                "status": status,
                "beats": [],
                "downbeats": [],
                "bpm": None,
                "confidence": 0.0,
                "runtime": {
                    "backend": None,
                    "requested_device": torch_device(),
                    "python_api_error": f"{type(python_exc).__name__}: {python_exc}",
                    "cli_error": f"{type(cli_exc).__name__}: {cli_exc}",
                },
                "timings": timer.snapshot(total_ms=status.runtime_ms),
                "warnings": list(status.warnings),
            }
    beats = beats[:max_beats]
    downbeats = downbeats[:max_beats]
    if not beats:
        status.status = "error"
        status.warnings = ["Beat This returned no beats; baseline beat grid is being used."]
    status.runtime_ms = timer.elapsed_ms()
    return {
        "status": status,
        "beats": beats,
        "downbeats": downbeats,
        "bpm": _estimate_bpm(beats),
        "confidence": 0.9 if beats else 0.0,
        "backend": backend,
        "runtime": runtime,
        "timings": timer.snapshot(total_ms=status.runtime_ms),
        "warnings": list(status.warnings),
    }


def warmup(model_dir: Path) -> ProviderStatus:
    started = perf_counter()
    root = model_dir / "beat_this" / "torch_home"
    root.mkdir(parents=True, exist_ok=True)
    previous_torch_home = os.environ.get("TORCH_HOME")
    os.environ["TORCH_HOME"] = str(root)
    try:
        from beat_this.inference import load_checkpoint

        load_checkpoint("final0", device="cpu")
    except Exception as exc:
        status = check(model_dir, True)
        status.status = "error"
        status.runtime_ms = int((perf_counter() - started) * 1000)
        status.warnings = [f"Beat This final0 Warmup failed: {type(exc).__name__}: {exc}"]
        return status
    finally:
        if previous_torch_home is None:
            os.environ.pop("TORCH_HOME", None)
        else:
            os.environ["TORCH_HOME"] = previous_torch_home
    status = check(model_dir, True)
    status.runtime_ms = int((perf_counter() - started) * 1000)
    return status


def _run_python_api(
    source: Path,
    model_dir: Path,
    timer: ProviderTimer,
) -> Tuple[List[float], List[float], Dict[str, object]]:
    with timer.stage("python_import"):
        from beat_this.inference import Audio2Beats, load_audio

    requested_device = "cuda" if torch_device() == "cuda" else "cpu"
    with timer.stage("checkpoint_find"):
        checkpoint = _find_checkpoint(model_dir)
    with timer.stage("model_init"):
        audio2beats = Audio2Beats(
            checkpoint_path=str(checkpoint),
            device=requested_device,
            float16=False,
            dbn=False,
        )
    with timer.stage("runtime_probe"):
        runtime = torch_model_runtime(
            audio2beats.model,
            backend="python_api",
            requested_device=requested_device,
            device=str(audio2beats.device),
            float16_enabled=bool(audio2beats.float16),
            autocast_enabled=bool(audio2beats.float16),
            inference_precision="float16_autocast" if audio2beats.float16 else "float32",
        )
    with timer.stage("load_audio"):
        signal, sample_rate = load_audio(str(source), dtype="float32")
    runtime.update(
        {
            "audio_dtype": str(getattr(signal, "dtype", "unknown")),
            "audio_shape": _shape_list(signal),
            "audio_sample_rate": int(sample_rate),
        }
    )
    with timer.stage("signal_to_spectrogram"):
        _sync_cuda()
        spectrogram = audio2beats.signal2spect(signal, sample_rate)
        _sync_cuda()
    runtime.update(
        {
            "spectrogram_dtype": str(getattr(spectrogram, "dtype", "unknown")).replace(
                "torch.", ""
            ),
            "spectrogram_device": str(getattr(spectrogram, "device", "unknown")),
            "spectrogram_shape": _shape_list(spectrogram),
        }
    )
    with timer.stage("model_forward"):
        _sync_cuda()
        beat_logits, downbeat_logits = audio2beats.spect2frames(spectrogram)
        _sync_cuda()
    runtime["model_output_dtypes"] = sorted(
        {
            str(getattr(beat_logits, "dtype", "unknown")).replace("torch.", ""),
            str(getattr(downbeat_logits, "dtype", "unknown")).replace("torch.", ""),
        }
    )
    with timer.stage("postprocess"):
        _sync_cuda()
        beats, downbeats = audio2beats.frames2beats(beat_logits, downbeat_logits)
    with timer.stage("coerce_times"):
        return _coerce_times(beats), _coerce_times(downbeats), runtime


def _run_cli(
    source: Path,
    model_dir: Path,
    timer: ProviderTimer,
) -> Tuple[List[float], List[float], Dict[str, object]]:
    with timer.stage("cli_find_executable"):
        executable = executable_path("beat_this")
    if not executable:
        raise RuntimeError("beat_this executable is not on PATH")
    with timer.stage("checkpoint_find"):
        checkpoint = _find_checkpoint(model_dir)
    runtime = {
        "backend": "cli",
        "requested_device": "cuda" if torch_device() == "cuda" else "cpu",
        "inference_precision": "unknown_cli",
    }
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / "beat_this.beats"
        command = [
            executable,
            str(source),
            "-o",
            str(output),
            "--gpu",
            "0" if torch_device() == "cuda" else "-1",
        ]
        if checkpoint:
            command.extend(["--checkpoint", str(checkpoint)])
        with timer.stage("cli_subprocess"):
            subprocess.run(
                command,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        with timer.stage("parse_output"):
            beats, downbeats = _parse_beats_file(output)
    return beats, downbeats, runtime


def _shape_list(value: object) -> List[int]:
    shape = getattr(value, "shape", None)
    if shape is None:
        return []
    try:
        return [int(item) for item in shape]
    except TypeError:
        return []


def _sync_cuda() -> None:
    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.synchronize()
    except Exception:
        pass


def _find_checkpoint(model_dir: Path) -> Path:
    root = model_dir / "beat_this"
    patterns = ("*.ckpt", "*.pt", "*.pth", "final*", "**/*.ckpt", "**/*.pt", "**/*.pth")
    for pattern in patterns:
        for path in root.glob(pattern):
            if path.is_file():
                return path
    raise FileNotFoundError(f"No Beat This checkpoint found under {root}")


def _parse_beats_file(path: Path) -> Tuple[List[float], List[float]]:
    beats: List[float] = []
    downbeats: List[float] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.replace(",", " ").split()
        try:
            time = float(parts[0])
        except (IndexError, ValueError):
            continue
        beats.append(time)
        if len(parts) > 1:
            try:
                position = int(float(parts[1]))
            except ValueError:
                position = 0
            if position == 1:
                downbeats.append(time)
    return _coerce_times(beats), _coerce_times(downbeats)


def _coerce_times(values: object) -> List[float]:
    out: List[float] = []
    if values is None:
        return out
    for item in _iter_time_items(values):
        try:
            if isinstance(item, (list, tuple)):
                value = float(item[0])
            else:
                value = float(item)
        except (TypeError, ValueError, IndexError):
            continue
        if value >= 0:
            out.append(round(value, 3))
    return sorted(set(out))


def _iter_time_items(values: object) -> Iterable[object]:
    if isinstance(values, Sequence) and not isinstance(values, (str, bytes)):
        return values
    try:
        return list(values)  # type: ignore[arg-type]
    except TypeError:
        return []


def _estimate_bpm(beats: List[float]) -> Optional[float]:
    if len(beats) < 2:
        return None
    diffs = [
        beats[index] - beats[index - 1]
        for index in range(1, len(beats))
        if beats[index] > beats[index - 1]
    ]
    if not diffs:
        return None
    diffs = sorted(diffs)
    step = diffs[len(diffs) // 2]
    return round(60.0 / step, 3) if step > 0 else None
