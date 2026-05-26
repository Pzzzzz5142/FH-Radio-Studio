from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf
from conftest import assert_cli_ok, run_cli, write_test_tone

from backend.fh_radio_studio_cli.loudness import (
    DEFAULT_TRUE_PEAK_CEILING_DBTP,
    LOUDNESS_ALGORITHM_VERSION,
    analyze_loudness_file,
    build_custom_set_loudness_profile,
    ensure_baseline_loudness_envelope,
    loudness_worker_count,
    prepare_loudness_matched_audio,
)


def test_loudness_matching_uses_baseline_reference_median_target(tmp_path: Path) -> None:
    loud = tmp_path / "loud.wav"
    quiet = tmp_path / "quiet.wav"
    _write_tone(loud, amplitude=0.85)
    _write_tone(quiet, amplitude=0.085)

    analyses = [analyze_loudness_file(path) for path in (loud, quiet)]
    profile = build_custom_set_loudness_profile(
        analyses,
        {
            "source": "heuristic",
            "reference_min_lufs": -28.0,
            "reference_median_lufs": -18.0,
            "reference_max_lufs": -16.0,
            "safe_min_lufs": -28.0,
            "safe_max_lufs": -16.0,
            "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
            "max_positive_gain_db": 8.0,
        },
        radio=4,
    )

    assert profile["raw_set_center_lufs"] != profile["target_lufs"]
    assert profile["reference_median_lufs"] == -18.0
    assert profile["target_lufs"] == -18.0
    assert profile["target_basis"] == "baseline-reference-median"

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
    assert any(item["requested_gain_db"] > 0 for item in outputs)


def test_loudness_positive_gain_is_capped_before_peak_check(tmp_path: Path) -> None:
    quiet = tmp_path / "very-quiet.wav"
    _write_tone(quiet, amplitude=0.002)
    analysis = analyze_loudness_file(quiet)
    profile = {
        "target_lufs": -24.0,
        "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
        "max_positive_gain_db": 6.0,
    }

    _before, _after, loudness = prepare_loudness_matched_audio(
        quiet,
        tmp_path / "out-quiet.wav",
        profile,
        input_analysis=analysis,
    )

    assert loudness["requested_gain_db"] > 6.0
    assert loudness["positive_gain_trim_db"] < 0
    assert loudness["applied_gain_db"] == 6.0
    assert loudness["limited_by_max_positive_gain"] is True
    assert "max_positive_gain_limited_boost" in loudness["warnings"]


def test_loudness_positive_gain_respects_true_peak_ceiling(tmp_path: Path) -> None:
    tone = tmp_path / "near-peak.wav"
    _write_tone(tone, amplitude=0.95)
    analysis = analyze_loudness_file(tone)
    profile = {
        "target_lufs": float(analysis["integrated_lufs"]) + 4.0,
        "true_peak_ceiling_dbtp": DEFAULT_TRUE_PEAK_CEILING_DBTP,
        "max_positive_gain_db": 8.0,
    }

    _before, _after, loudness = prepare_loudness_matched_audio(
        tone,
        tmp_path / "out-near-peak.wav",
        profile,
        input_analysis=analysis,
    )

    assert loudness["requested_gain_db"] > 0
    assert loudness["true_peak_trim_db"] < 0
    assert loudness["output_true_peak_dbtp"] <= DEFAULT_TRUE_PEAK_CEILING_DBTP + 0.1
    assert loudness["limited_by_true_peak"] is True
    assert "true_peak_ceiling_limited_gain" in loudness["warnings"]


def test_heuristic_envelope_contains_required_global_stats() -> None:
    envelope = ensure_baseline_loudness_envelope(None)

    assert envelope["source"] == "heuristic"
    assert envelope["algorithm_version"] == LOUDNESS_ALGORITHM_VERSION
    for key in (
        "reference_min_lufs",
        "reference_median_lufs",
        "reference_max_lufs",
        "safe_min_lufs",
        "safe_max_lufs",
    ):
        assert isinstance(envelope[key], float)


def test_loudness_worker_count_uses_two_as_auto_floor(monkeypatch) -> None:
    monkeypatch.setattr(
        "backend.fh_radio_studio_cli.loudness.os.cpu_count",
        lambda: 16,
    )

    assert loudness_worker_count(0, 237) == 8
    assert loudness_worker_count(0, 3) == 3
    assert loudness_worker_count(1, 12) == 1
    assert loudness_worker_count(8, 3) == 3
    assert loudness_worker_count(0, 1) == 1

    monkeypatch.setattr(
        "backend.fh_radio_studio_cli.loudness.os.cpu_count",
        lambda: 2,
    )
    assert loudness_worker_count(0, 12) == 2


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
    assert envelope["algorithm_version"] == LOUDNESS_ALGORITHM_VERSION
    for key in (
        "reference_min_lufs",
        "reference_median_lufs",
        "reference_max_lufs",
        "safe_min_lufs",
        "safe_max_lufs",
    ):
        assert isinstance(envelope[key], (float, int))

    package_payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert package_payload["loudness_mode"] == "custom-set"
    assert "gain_db" not in package_payload
    radio_payload = package_payload["radios"][0]
    assert radio_payload["loudness_profile"]["mode"] == "custom-set"
    assert (
        radio_payload["loudness_profile"]["target_lufs"]
        == radio_payload["loudness_profile"]["reference_median_lufs"]
    )
    track = radio_payload["music"][0]
    assert track["loudness"]["mode"] == "custom-set"
    assert "input_integrated_lufs" in track["loudness"]
    assert track["loudness"]["output_verified"] is False
    assert Path(track["prepared_wav"]).exists()
    cache_payload = json.loads(metadata_cache.read_text(encoding="utf-8"))
    cached = cache_payload["tracks"][0]["loudness_analysis"]
    assert cached["status"] == "ok"
    assert cached["algorithm_version"] == LOUDNESS_ALGORITHM_VERSION


def _write_tone(
    path: Path, *, amplitude: float, duration_sec: float = 6.0, sample_rate: int = 48000
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    t = np.arange(int(duration_sec * sample_rate), dtype=np.float32) / sample_rate
    mono = (amplitude * np.sin(2 * math.pi * 440.0 * t)).astype(np.float32)
    stereo = np.column_stack([mono, mono])
    sf.write(str(path), stereo, sample_rate, subtype="PCM_16")
