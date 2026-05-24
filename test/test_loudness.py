from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf
from conftest import assert_cli_ok, run_cli, write_test_tone

from backend.fh_radio_studio_cli.loudness import (
    DEFAULT_TRUE_PEAK_CEILING_DBTP,
    analyze_loudness_file,
    build_custom_set_loudness_profile,
    prepare_loudness_matched_audio,
)


def test_loudness_matching_uses_custom_set_target(tmp_path: Path) -> None:
    loud = tmp_path / "loud.wav"
    quiet = tmp_path / "quiet.wav"
    _write_tone(loud, amplitude=0.85)
    _write_tone(quiet, amplitude=0.085)

    analyses = [analyze_loudness_file(path) for path in (loud, quiet)]
    profile = build_custom_set_loudness_profile(
        analyses,
        {
            "source": "heuristic",
            "safe_min_lufs": -28.0,
            "safe_max_lufs": -16.0,
            "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
        },
        radio=4,
    )

    outputs = []
    for source in (loud, quiet):
        dst = tmp_path / f"out-{source.name}"
        _before, _after, loudness = prepare_loudness_matched_audio(
            source,
            dst,
            profile,
        )
        outputs.append(loudness)

    delta = abs(outputs[0]["output_integrated_lufs"] - outputs[1]["output_integrated_lufs"])
    assert delta <= 0.5
    assert all(
        item["output_true_peak_dbtp"] <= DEFAULT_TRUE_PEAK_CEILING_DBTP + 0.1 for item in outputs
    )


def test_build_package_writes_loudness_manifest_and_baseline_envelope(mock_game, tmp_path) -> None:
    source = tmp_path / "sources" / "FH Radio Studio Dev - Loudness.wav"
    baseline_dir = tmp_path / "backups" / "baseline-current"
    package_dir = tmp_path / "packages" / "loudness"
    write_test_tone(source, duration_sec=2.0)

    baseline = run_cli(
        "baseline",
        "create",
        "--game-dir",
        str(mock_game.game_dir),
        "--out-dir",
        str(baseline_dir),
        "--state",
        "current",
        "--yes",
    )
    assert_cli_ok(baseline)
    baseline_manifest = baseline_dir / "baseline_manifest.json"
    metadata_cache = tmp_path / "project" / ".fh-radio-studio" / "track_metadata.json"

    build = run_cli(
        "build-package",
        str(source),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--out-dir",
        str(package_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--metadata-cache",
        str(metadata_cache),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )
    assert_cli_ok(build)
    assert "Loudness matching: custom set profile ready." in build.stdout
    assert "Loudness cache miss: measuring 1 song(s) with 1 process(es)." in build.stdout
    assert "Loudness cache: 0 hit(s), 1 measured + cached." in build.stdout

    baseline_payload = json.loads(baseline_manifest.read_text(encoding="utf-8"))
    envelope = baseline_payload["derived_values"]["loudness_envelope"]
    assert envelope["kind"] == "baseline_loudness_envelope"
    assert envelope["source"] in {"measured", "heuristic"}

    package_payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert package_payload["loudness_mode"] == "custom-set"
    assert "gain_db" not in package_payload
    radio_payload = package_payload["radios"][0]
    assert radio_payload["loudness_profile"]["mode"] == "custom-set"
    track = radio_payload["music"][0]
    assert track["loudness"]["mode"] == "custom-set"
    assert "input_integrated_lufs" in track["loudness"]
    assert track["loudness"]["output_verified"] is False
    assert Path(track["prepared_wav"]).exists()
    cache_payload = json.loads(metadata_cache.read_text(encoding="utf-8"))
    cached = cache_payload["tracks"][0]["loudness_analysis"]
    assert cached["status"] == "ok"
    assert cached["algorithm_version"] == "fh-radio-studio-loudness-v1"


def _write_tone(
    path: Path, *, amplitude: float, duration_sec: float = 6.0, sample_rate: int = 48000
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    t = np.arange(int(duration_sec * sample_rate), dtype=np.float32) / sample_rate
    mono = (amplitude * np.sin(2 * math.pi * 440.0 * t)).astype(np.float32)
    stereo = np.column_stack([mono, mono])
    sf.write(str(path), stereo, sample_rate, subtype="PCM_16")
