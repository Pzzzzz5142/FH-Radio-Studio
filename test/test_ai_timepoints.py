from __future__ import annotations

import json
import os
import sys
import types
from pathlib import Path

import numpy as np
from conftest import assert_cli_ok, run_cli, write_test_tone

from backend.fh_radio_studio_cli.ai_timepoints.cli import (
    _apply_timing_constraints,
    cmd_prepare_ai_cache,
)
from backend.fh_radio_studio_cli.ai_timepoints.generation.ranker import (
    sort_post_loop_candidates,
    sort_track_loop_candidates,
)
from backend.fh_radio_studio_cli.ai_timepoints.providers import (
    baseline_mir,
    hf_download,
    mert,
    songformer,
)
from backend.fh_radio_studio_cli.ai_timepoints.schema import ProviderStatus


def test_analyze_audio_emits_stable_contract(tmp_path) -> None:
    source = tmp_path / "source.wav"
    write_test_tone(source, duration_sec=96.0)
    model_dir = tmp_path / "models"

    result = run_cli(
        "analyze-audio",
        str(source),
        "--profile",
        "local-heavy",
        "--model-dir",
        str(model_dir),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["schema_version"] == 2
    assert payload["analysis"]["profile"] == "local-heavy"
    assert payload["analysis"]["write_sample_rate"] == 48000
    timings = payload["analysis"]["timings"]
    assert timings["total_ms"] >= 0
    stage_names = [item["name"] for item in timings["stages"]]
    assert "baseline_mir.analyze" in stage_names
    assert "constraints.after_demucs" in stage_names
    assert "finalize_payload" in stage_names
    assert isinstance(payload["analysis"]["provider_timings"], dict)
    assert isinstance(payload["analysis"]["provider_runtime"], dict)
    assert payload["grid"]["beats"]
    assert payload["grid"]["downbeats"]
    assert payload["candidates"]["td"]
    assert payload["candidates"]["pd"]
    assert payload["candidates"]["tl"]
    assert payload["candidates"]["pl"]
    assert payload["analysis"]["provider_statuses"][0]["name"] == "baseline_mir"
    assert payload["analysis"]["provider_statuses"][0]["status"] == "ok"
    assert any(
        item["name"] == "mert" and item["status"] in {"missing", "partial"}
        for item in payload["analysis"]["provider_statuses"]
    )


def test_analyze_audio_emits_progress_jsonl_on_stderr(tmp_path) -> None:
    source = tmp_path / "progress.wav"
    write_test_tone(source, duration_sec=12.0)
    model_dir = tmp_path / "models"

    result = run_cli(
        "analyze-audio",
        str(source),
        "--profile",
        "local-heavy",
        "--model-dir",
        str(model_dir),
        "--json",
        "--progress-jsonl",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["schema_version"] == 2

    progress_prefix = "FH_RADIO_STUDIO_PROGRESS "
    events = [
        json.loads(line[len(progress_prefix) :])
        for line in result.stderr.splitlines()
        if line.startswith(progress_prefix)
    ]
    assert events[0]["event"] == "plan"
    plan_step_ids = [step["id"] for step in events[0]["steps"]]
    assert plan_step_ids[:5] == [
        "setup",
        "beat_this.check",
        "songformer.check",
        "mert.check",
        "demucs.check",
    ]
    assert "beat_this.analyze" in plan_step_ids
    assert "baseline_mir.analyze" in plan_step_ids
    assert "mert.score_candidates" in plan_step_ids
    started = [event["step_id"] for event in events if event["event"] == "step_started"]
    assert "beat_this.check" in started
    assert "baseline_mir.analyze" in started
    completed = {event["step_id"]: event for event in events if event["event"] == "step_completed"}
    assert completed["setup"]["status"] == "done"
    assert completed["baseline_mir.analyze"]["status"] == "done"
    assert completed["mert.check"]["status"] in {"done", "warning"}
    assert completed["mert.score_candidates"]["status"] == "skipped"
    assert all("runtime_ms" in event for event in completed.values())


def test_analyze_audio_local_base_progress_omits_deep_provider_checks(tmp_path) -> None:
    source = tmp_path / "local-base-progress.wav"
    write_test_tone(source, duration_sec=12.0)

    result = run_cli(
        "analyze-audio",
        str(source),
        "--profile",
        "local-base",
        "--json",
        "--progress-jsonl",
    )

    assert_cli_ok(result)

    progress_prefix = "FH_RADIO_STUDIO_PROGRESS "
    events = [
        json.loads(line[len(progress_prefix) :])
        for line in result.stderr.splitlines()
        if line.startswith(progress_prefix)
    ]
    plan_step_ids = [step["id"] for step in events[0]["steps"]]
    assert plan_step_ids == [
        "setup",
        "baseline_mir.analyze",
        "constraints.after_structure",
        "constraints.after_demucs",
        "finalize_payload",
    ]
    assert all(".check" not in step_id for step_id in plan_step_ids)
    completed = [event for event in events if event["event"] == "step_completed"]
    assert all(event["status"] != "skipped" for event in completed)


def test_analyze_audio_baseline_mir_emits_local_evidence(tmp_path) -> None:
    source = tmp_path / "loopable.wav"
    write_test_tone(source, duration_sec=64.0)
    model_dir = tmp_path / "models"

    result = run_cli(
        "analyze-audio",
        str(source),
        "--profile",
        "local-heavy",
        "--model-dir",
        str(model_dir),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["segments"]
    assert payload["segments"][0]["provider"] == "baseline_mir"

    point_evidence = payload["candidates"]["td"][0]["evidence"]
    assert point_evidence["quality"] == "local_base"
    assert point_evidence["providers"] == ["baseline_mir"]
    assert "energy_jump" in point_evidence
    assert "spectral_flux" in point_evidence
    assert "nearest_downbeat_delta_ms" in point_evidence

    loop_evidence = payload["candidates"]["tl"][0]["evidence"]
    assert loop_evidence["quality"] == "local_base"
    assert loop_evidence["providers"] == ["baseline_mir"]
    assert "seam_similarity" in loop_evidence
    assert "rms_delta_db" in loop_evidence


def test_baseline_mir_uses_injected_beat_provider_grid(tmp_path) -> None:
    source = tmp_path / "with-beats.wav"
    write_test_tone(source, duration_sec=24.0)

    beats = [index * 0.5 for index in range(48)]
    payload = baseline_mir.analyze(
        source,
        bins=64,
        bpm=120.0,
        max_beats=128,
        ffmpeg=None,
        beat_evidence={
            "provider": "beat_this",
            "beats": beats,
            "downbeats": beats[::4],
            "confidence": 0.9,
        },
    )

    assert payload["grid"]["provider"] == "beat_this"
    assert payload["bpm"] == 120.0
    assert payload["bpm_confidence"] >= 0.9
    assert payload["candidates"]["td"]
    assert payload["candidates"]["tl"]


def test_baseline_mir_prefers_long_loop_without_overtrusting_weak_trackdrop(tmp_path) -> None:
    source = tmp_path / "long-loopable.wav"
    write_test_tone(source, duration_sec=64.0)

    beats = [index * 0.5 for index in range(128)]
    payload = baseline_mir.analyze(
        source,
        bins=64,
        bpm=120.0,
        max_beats=160,
        ffmpeg=None,
        beat_evidence={
            "provider": "beat_this",
            "beats": beats,
            "downbeats": beats[::4],
            "confidence": 0.9,
        },
    )

    track_loop = payload["candidates"]["tl"][0]
    assert int(track_loop["bars"]) >= 16
    assert track_loop["evidence"]["loop_duration_sec"] >= 32.0


def test_baseline_mir_keeps_post_drop_and_post_loop_flexible(tmp_path) -> None:
    source = tmp_path / "post-flexible.wav"
    write_test_tone(source, duration_sec=64.0)

    beats = [index * 0.5 for index in range(128)]
    payload = baseline_mir.analyze(
        source,
        bins=64,
        bpm=120.0,
        max_beats=160,
        ffmpeg=None,
        beat_evidence={
            "provider": "beat_this",
            "beats": beats,
            "downbeats": beats[::4],
            "confidence": 0.9,
        },
    )

    post_drop = float(payload["candidates"]["pd"][0]["t"])
    assert any(float(item["t"]) < 64.0 * 0.55 for item in payload["candidates"]["pd"])
    assert any(float(item["start"]) < post_drop for item in payload["candidates"]["pl"])
    assert int(payload["candidates"]["pl"][0]["bars"]) <= 16


def test_baseline_mir_keeps_sub_four_second_trackdrop_candidate() -> None:
    duration = 200.0
    times = np.linspace(0.0, 12.0, 121, dtype=np.float32)
    novelty = np.zeros_like(times)
    novelty[int(np.argmin(np.abs(times - 3.0)))] = 0.9
    rms = np.where(times >= 3.0, 0.55, 0.12).astype(np.float32)
    flux = np.zeros_like(times)
    flux[int(np.argmin(np.abs(times - 3.0)))] = 0.8
    features = {
        "times": times,
        "novelty": novelty,
        "rms": rms,
        "flux": flux,
    }
    grid = {
        "beats": [index * 0.5 for index in range(32)],
        "downbeats": [index * 2.0 for index in range(8)],
    }

    candidates = baseline_mir._trackdrop_point_candidates(
        duration,
        features,
        grid,
        beat_step=0.5,
        fallback=30.0,
    )

    early = next((item for item in candidates if abs(float(item["t"]) - 3.0) < 0.001), None)
    assert early is not None
    assert early["evidence"]["track_start_role"] == "recognizable_intro_base_kickoff"
    assert early["evidence"]["nearest_downbeat_delta_ms"] != 0


def test_baseline_mir_considers_early_downbeat_energy_jump_without_peak() -> None:
    duration = 215.0
    times = np.array([1.0, 3.56, 4.74, 5.92, 6.32, 6.923, 8.32, 10.72], dtype=np.float32)
    features = {
        "times": times,
        "novelty": np.array([0.0, 0.28, 0.42, 0.53, 0.55, 0.56, 0.50, 0.52], dtype=np.float32),
        "rms": np.array([0.0, 0.01, 0.01, 0.36, 0.34, 0.33, 0.35, 0.36], dtype=np.float32),
        "flux": np.array([0.0, 0.18, 0.22, 0.36, 0.34, 0.31, 0.27, 0.24], dtype=np.float32),
    }
    grid = {
        "beats": [index * 0.4 for index in range(40)],
        "downbeats": [0.02, 1.22, 1.60, 2.76, 3.56, 4.74, 5.92, 8.32, 10.72],
    }

    candidates = baseline_mir._trackdrop_point_candidates(
        duration,
        features,
        grid,
        beat_step=0.4,
        fallback=16.0,
    )

    early_downbeat = next(
        (item for item in candidates if abs(float(item["t"]) - 5.92) < 0.001), None
    )
    assert early_downbeat is not None
    assert early_downbeat["evidence"]["nearest_downbeat_delta_ms"] == 0
    assert early_downbeat["evidence"]["energy_jump"] > 0.2


def test_songformer_keeps_early_intro_base_trackdrop_candidate() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 10.32, "label": "intro", "confidence": 0.78},
        {"start": 10.32, "end": 34.561, "label": "intro", "confidence": 0.78},
        {"start": 76.563, "end": 98.524, "label": "chorus", "confidence": 0.78},
    ]
    grid = {"downbeats": [23.94, 26.48, 29.14]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=317.707,
    )

    top = out["td"][0]
    assert float(top["t"]) == 10.32
    assert top["evidence"]["track_start_role"] == "recognizable_intro_base_kickoff"
    assert "intro/base kickoff" in top["why"]


def test_songformer_adds_zero_trackdrop_candidate_for_short_merged_intro() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 1.2, "label": "intro", "confidence": 0.78},
        {"start": 1.2, "end": 15.721, "label": "verse", "confidence": 0.78},
        {"start": 15.721, "end": 31.801, "label": "verse", "confidence": 0.78},
    ]
    grid = {"downbeats": [0.0, 1.2, 3.34, 5.26]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=200.248,
    )

    top = out["td"][0]
    assert float(top["t"]) == 0.0
    assert top["evidence"]["songformer_point_role"] == "short_intro_start"
    assert top["evidence"]["track_start_role"] == "short_intro_start"
    assert top["evidence"]["track_start_policy"] == "include_zero_for_short_intro"
    assert top["evidence"]["merged_intro_end"] == 1.2
    assert top["evidence"]["next_segment_label"] == "verse"


def test_songformer_does_not_add_zero_trackdrop_for_normal_merged_intro() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 8.0, "label": "intro", "confidence": 0.78},
        {"start": 8.0, "end": 20.0, "label": "verse", "confidence": 0.78},
    ]
    grid = {"downbeats": [0.0, 2.0, 4.0, 6.0, 8.0]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=120.0,
    )

    assert all(
        item["evidence"].get("songformer_point_role") != "short_intro_start" for item in out["td"]
    )


def test_songformer_adds_zero_trackdrop_candidate_when_song_has_no_intro() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 18.0, "label": "verse", "confidence": 0.78},
        {"start": 18.0, "end": 36.0, "label": "chorus", "confidence": 0.78},
    ]
    grid = {"downbeats": [0.0, 2.0, 4.0, 6.0]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=180.0,
    )

    top = out["td"][0]
    assert float(top["t"]) == 0.0
    assert top["evidence"]["songformer_point_role"] == "no_intro_start"
    assert top["evidence"]["track_start_role"] == "no_intro_start"
    assert top["evidence"]["track_start_policy"] == "include_zero_for_no_intro"
    assert top["evidence"]["songformer_label"] == "verse"


def test_songformer_no_intro_zero_requires_immediate_playable_segment() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 2.0, "label": "silence", "confidence": 0.78},
        {"start": 2.0, "end": 18.0, "label": "verse", "confidence": 0.78},
    ]
    grid = {"downbeats": [0.0, 2.0, 4.0, 6.0]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=180.0,
    )

    assert all(
        item["evidence"].get("songformer_point_role") != "no_intro_start" for item in out["td"]
    )


def test_songformer_trackdrop_ignores_post_intro_chorus_boundary() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 28.0, "label": "intro", "confidence": 0.78},
        {"start": 28.0, "end": 62.0, "label": "intro", "confidence": 0.78},
        {"start": 82.82, "end": 108.0, "label": "chorus", "confidence": 0.78},
    ]
    grid = {"downbeats": [28.0, 39.28, 82.82]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=197.0,
    )

    assert all(abs(float(item["t"]) - 82.82) > 0.01 for item in out["td"])
    assert all("chorus boundary" not in item["why"] for item in out["td"])


def test_constraints_filter_trackdrop_candidates_after_intro_cap() -> None:
    segments = [
        {"start": 0.0, "end": 28.0, "label": "intro", "confidence": 0.78},
        {"start": 28.0, "end": 62.0, "label": "intro", "confidence": 0.78},
        {"start": 82.82, "end": 108.0, "label": "chorus", "confidence": 0.78},
    ]
    candidates = {
        "td": [
            {
                "t": 82.82,
                "score": 0.95,
                "why": "TrackDrop · SongFormer chorus boundary",
                "evidence": {},
            },
            {
                "t": 39.28,
                "score": 0.72,
                "why": "TrackDrop · SongFormer long intro downbeat",
                "evidence": {},
            },
        ],
        "pd": [],
        "tl": [],
        "pl": [],
    }

    out = _apply_timing_constraints(
        candidates, {"bars": [{"start": 0.0}, {"start": 2.0}]}, 197.0, segments=segments
    )

    assert [float(item["t"]) for item in out["td"]] == [39.28]


def test_constraints_preserve_short_intro_zero_policy() -> None:
    candidates = {
        "td": [
            {
                "t": 0.0,
                "score": 0.58,
                "why": "TrackDrop · short intro",
                "evidence": {
                    "track_start_role": "short_intro_start",
                    "track_start_policy": "include_zero_for_short_intro",
                },
            }
        ],
        "pd": [],
        "tl": [],
        "pl": [],
    }

    out = _apply_timing_constraints(candidates, {"bars": [{"start": 0.0}, {"start": 2.0}]}, 200.0)

    evidence = out["td"][0]["evidence"]
    assert evidence["track_start_policy"] == "include_zero_for_short_intro"
    assert evidence["track_start_bonus_policy"] == "prefer recognizable intro/base kickoff"


def test_songformer_long_intro_scans_downbeats_inside_intro_runway() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 2.04, "label": "silence", "confidence": 0.78},
        {"start": 2.04, "end": 21.001, "label": "intro", "confidence": 0.78},
        {"start": 21.001, "end": 40.082, "label": "intro", "confidence": 0.78},
        {"start": 40.082, "end": 62.763, "label": "intro", "confidence": 0.78},
        {"start": 62.763, "end": 85.323, "label": "verse", "confidence": 0.78},
    ]
    grid = {
        "downbeats": [40.3, 43.12, 45.94, 48.78, 51.6, 54.42, 57.24, 60.06],
    }

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=302.0,
    )

    top = out["td"][0]
    assert float(top["t"]) == 51.6
    assert top["evidence"]["songformer_point_role"] == "long_intro_downbeat"
    assert top["evidence"]["long_intro_end"] == 62.763
    assert "long intro downbeat" in top["why"]


def test_songformer_adds_late_postdrop_payoff_downbeats() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 165.247, "end": 197.168, "label": "chorus", "confidence": 0.78},
        {"start": 197.168, "end": 226.449, "label": "bridge", "confidence": 0.78},
        {"start": 226.449, "end": 258.49, "label": "chorus", "confidence": 0.78},
    ]
    grid = {"downbeats": [197.3, 210.62, 213.3, 215.94, 226.64]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=317.707,
    )

    times = [float(item["t"]) for item in out["pd"]]
    assert any(abs(time - 197.3) < 0.01 for time in times)
    assert any(abs(time - 213.3) < 0.01 for time in times)
    payoff = next(item for item in out["pd"] if abs(float(item["t"]) - 213.3) < 0.01)
    assert payoff["evidence"]["songformer_point_role"] == "payoff_downbeat"


def test_songformer_postdrop_payoff_does_not_change_trackdrop_ranking() -> None:
    candidates = {"td": [], "pd": [], "tl": [], "pl": []}
    segments = [
        {"start": 0.0, "end": 10.32, "label": "intro", "confidence": 0.78},
        {"start": 10.32, "end": 34.561, "label": "intro", "confidence": 0.78},
        {"start": 34.561, "end": 56.042, "label": "verse", "confidence": 0.78},
        {"start": 197.168, "end": 226.449, "label": "bridge", "confidence": 0.78},
    ]
    grid = {"downbeats": [10.32, 23.94, 34.62, 197.3, 213.3]}

    out = songformer.add_structure_point_candidates(
        candidates,
        segments,
        grid=grid,
        duration=317.707,
    )

    assert float(out["td"][0]["t"]) == 10.32
    assert "songformer_point_role" not in out["td"][0]["evidence"]
    assert any(
        item["evidence"].get("songformer_point_role") == "payoff_downbeat" for item in out["pd"]
    )


def test_loop_sort_tie_prefers_longer_loop() -> None:
    items = [
        {"start": 10.0, "end": 42.0, "bars": 16, "score": 0.8},
        {"start": 10.0, "end": 74.0, "bars": 32, "score": 0.8},
    ]

    assert sort_track_loop_candidates(items)[0]["bars"] == 32


def test_post_loop_sort_tie_prefers_chorus_sized_loop() -> None:
    items = [
        {"start": 10.0, "end": 42.0, "bars": 16, "score": 0.8},
        {"start": 10.0, "end": 30.0, "bars": 8, "score": 0.8},
        {"start": 10.0, "end": 138.0, "bars": 64, "score": 0.8},
    ]

    assert sort_post_loop_candidates(items)[0]["bars"] == 8


def test_track_loop_anchor_is_hard_only_for_confident_trackdrop() -> None:
    grid = {"bars": [{"start": 0.0}, {"start": 4.0}, {"start": 8.0}]}
    candidates = {
        "td": [
            {
                "t": 20.0,
                "score": 0.8,
                "evidence": {"track_start_role": "recognizable_intro_base_kickoff"},
            }
        ],
        "tl": [
            {"start": 18.0, "end": 66.0, "bars": 12, "score": 0.9, "evidence": {}},
            {"start": 28.0, "end": 92.0, "bars": 16, "score": 0.7, "evidence": {}},
        ],
        "pd": [],
        "pl": [],
    }

    out = _apply_timing_constraints(candidates, grid, 120.0)

    assert [item["start"] for item in out["tl"]] == [28.0]
    assert out["tl"][0]["evidence"]["trackdrop_anchor_policy"] == "hard_high_confidence"


def test_track_loop_anchor_is_soft_for_low_confidence_trackdrop() -> None:
    grid = {"bars": [{"start": 0.0}, {"start": 4.0}, {"start": 8.0}]}
    candidates = {
        "td": [{"t": 20.0, "score": 0.4, "evidence": {}}],
        "tl": [
            {"start": 18.0, "end": 66.0, "bars": 12, "score": 0.9, "evidence": {}},
            {"start": 28.0, "end": 92.0, "bars": 16, "score": 0.7, "evidence": {}},
        ],
        "pd": [],
        "pl": [],
    }

    out = _apply_timing_constraints(candidates, grid, 120.0)

    starts = [item["start"] for item in out["tl"]]
    assert 18.0 in starts
    assert 28.0 in starts
    early_loop = next(item for item in out["tl"] if item["start"] == 18.0)
    assert early_loop["evidence"]["trackdrop_anchor_policy"] == "soft_low_confidence"
    assert early_loop["evidence"]["track_loop_anchor_penalty"] > 0


def test_track_loop_policy_prefers_compatible_section_seam() -> None:
    grid = {"bars": [{"start": 0.0}, {"start": 4.0}, {"start": 8.0}]}
    segments = [
        {"start": 40.0, "end": 60.0, "label": "verse"},
        {"start": 60.0, "end": 90.0, "label": "chorus"},
        {"start": 120.0, "end": 150.0, "label": "verse"},
        {"start": 210.0, "end": 235.0, "label": "bridge"},
    ]
    candidates = {
        "td": [],
        "tl": [
            {"start": 53.3, "end": 222.26, "bars": 64, "score": 0.86, "evidence": {}},
            {"start": 49.3, "end": 133.78, "bars": 32, "score": 0.74, "evidence": {}},
        ],
        "pd": [],
        "pl": [],
    }

    out = _apply_timing_constraints(candidates, grid, 240.0, segments=segments)

    assert out["tl"][0]["start"] == 49.3
    assert out["tl"][0]["evidence"]["track_loop_label_compatibility"] == 1.0
    mismatched = next(item for item in out["tl"] if item["start"] == 53.3)
    assert mismatched["evidence"]["track_loop_policy_penalty"] > 0


def test_post_loop_policy_enforces_end_gap_after_postdrop() -> None:
    grid = {"bars": [{"start": 0.0}, {"start": 4.0}, {"start": 8.0}]}
    candidates = {
        "td": [],
        "tl": [],
        "pd": [{"t": 118.0, "score": 0.7, "evidence": {}}],
        "pl": [
            {"start": 44.0, "end": 172.0, "bars": 64, "score": 0.82, "evidence": {}},
            {"start": 100.0, "end": 116.0, "bars": 8, "score": 0.74, "evidence": {}},
            {"start": 104.0, "end": 136.0, "bars": 16, "score": 0.76, "evidence": {}},
            {"start": 100.0, "end": 140.0, "bars": 20, "score": 0.77, "evidence": {}},
        ],
    }
    segments = [
        {"start": 0.0, "end": 80.0, "label": "verse"},
        {"start": 96.0, "end": 150.0, "label": "chorus"},
        {"start": 150.0, "end": 180.0, "label": "outro"},
    ]

    out = _apply_timing_constraints(candidates, grid, 180.0, segments=segments)

    top = out["pl"][0]
    assert top["start"] == 100.0
    assert top["end"] == 140.0
    assert top["end"] - candidates["pd"][0]["t"] >= 20.0
    assert all(float(item["end"]) - float(item["start"]) >= 20.0 for item in out["pl"])
    assert all(float(item["end"]) - candidates["pd"][0]["t"] >= 20.0 for item in out["pl"])
    assert top["evidence"]["post_loop_policy"] == "prefer short chorus loop"
    assert top["evidence"]["post_loop_chorus_overlap"] >= 0.99
    assert top["evidence"]["post_loop_postdrop_anchor"] == 1.0
    assert top["evidence"]["post_loop_min_duration_sec"] == 20.0


def test_postdrop_quality_is_preserved_before_post_loop_constraints() -> None:
    grid = {"bars": [{"start": 0.0}, {"start": 4.0}, {"start": 8.0}]}
    candidates = {
        "td": [],
        "tl": [],
        "pd": [
            {"t": 130.0, "score": 0.92, "evidence": {}},
            {"t": 110.0, "score": 0.70, "evidence": {}},
        ],
        "pl": [
            {"start": 120.0, "end": 150.0, "bars": 15, "score": 0.80, "evidence": {}},
        ],
    }
    segments = [
        {"start": 120.0, "end": 155.0, "label": "chorus"},
    ]

    out = _apply_timing_constraints(candidates, grid, 160.0, segments=segments)

    assert [float(item["t"]) for item in out["pd"]] == [130.0, 110.0]
    assert out["pl"][0]["end"] == 150.0
    assert out["pl"][0]["end"] - out["pd"][0]["t"] >= 20.0
    assert out["pl"][0]["evidence"]["postdrop_anchor_sec"] == 130.0


def test_check_ai_tools_is_offline_safe() -> None:
    result = run_cli(
        "check-ai-tools",
        "--profile",
        "local-heavy",
        "--model-dir",
        "test/fixtures/.tmp/empty-ai-models",
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["runtime_network_required"] is False
    assert [item["name"] for item in payload["providers"]][:2] == [
        "baseline_mir",
        "beat_this",
    ]


def test_toolchain_status_reports_uv_python_audio_and_ai_layers(tmp_path) -> None:
    result = run_cli(
        "toolchain-status",
        "--profile",
        "local-heavy",
        "--model-dir",
        str(tmp_path / "models"),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["schema_version"] == 1
    assert payload["runtime_network_required"] is False
    assert payload["install_network_required"] is True
    assert payload["profile"] == "local-heavy"
    assert set(payload["sections"]) >= {
        "uv",
        "audio_tools",
        "python",
        "hardware",
        "ai",
    }
    assert payload["sections"]["uv"]["title"] == "uv 运行时"
    assert payload["sections"]["python"]["items"][1]["value"] == "超大杯"
    assert payload["sections"]["ai"]["model_dir"] == str((tmp_path / "models").resolve())
    assert payload["dependency_sync"]["groups"] == [
        "ai-beat-this",
        "ai-mert",
        "ai-songformer",
        "ai-demucs",
    ]
    assert isinstance(payload["fixes"], list)


def test_prepare_ai_cache_writes_uv_manifest_and_cache_layout(tmp_path) -> None:
    model_dir = tmp_path / "models"

    result = run_cli(
        "prepare-ai-cache",
        "--profile",
        "local-heavy",
        "--model-dir",
        str(model_dir),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    manifest_path = model_dir / "ai_tools_manifest.json"
    assert payload["manifest"] == str(manifest_path.resolve())
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["package_manager"] == "uv"
    assert manifest["runtime_network_required"] is False
    assert manifest["install_network_required"] is True
    assert manifest["dependency_sync"]["groups"] == [
        "ai-beat-this",
        "ai-mert",
        "ai-songformer",
        "ai-demucs",
    ]
    assert manifest["dependency_sync"]["command"].startswith("uv sync ")
    assert manifest["dependency_sync"]["torch_extras"] == ["torch-cpu", "torch-cu128"]
    assert manifest["torch"]["selection"] == "runtime-detected-extra"
    assert manifest["torch"]["extras"] == ["torch-cpu", "torch-cu128"]

    providers = {item["name"]: item for item in manifest["providers"]}
    assert providers["beat_this"]["dependency_groups"] == ["ai-beat-this"]
    assert "uv_commands" not in providers["beat_this"]
    assert providers["beat_this"]["requires_torch"] is True
    assert providers["mert"]["model_id"] == "m-a-p/MERT-v1-95M"
    assert providers["mert"]["dependency_groups"] == ["ai-mert"]
    assert providers["mert"]["replaceable_model_dir"] == str(
        (model_dir / "mert" / "repo").resolve()
    )
    assert providers["songformer"]["model_id"] == "ASLP-lab/SongFormer"
    assert providers["songformer"]["dependency_groups"] == ["ai-songformer"]
    assert providers["songformer"]["replaceable_model_dir"] == str(
        (model_dir / "songformer" / "repo").resolve()
    )
    assert providers["demucs"]["model_id"] == "htdemucs"
    assert providers["demucs"]["dependency_groups"] == ["ai-demucs"]
    assert (model_dir / "beat_this").is_dir()
    assert (model_dir / "mert").is_dir()
    assert (model_dir / "songformer").is_dir()
    assert (model_dir / "demucs").is_dir()


def test_prepare_ai_cache_returns_failure_when_warmup_provider_fails(
    tmp_path, monkeypatch, capsys
) -> None:
    model_dir = tmp_path / "models"

    def fail_warmup(_model_dir: Path) -> ProviderStatus:
        return ProviderStatus(
            name="songformer",
            status="error",
            warnings=["SongFormer Warmup failed: test failure"],
        )

    monkeypatch.setattr(songformer, "warmup", fail_warmup)
    args = types.SimpleNamespace(
        model_dir=str(model_dir),
        profile="local-heavy",
        warmup_provider=["songformer"],
        json=True,
    )

    exit_code = cmd_prepare_ai_cache(args)

    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert exit_code == 1
    assert payload["status"] == "error"
    assert payload["warmup_failed"] is True
    assert payload["failed_providers"][0]["name"] == "songformer"
    assert payload["failed_providers"][0]["status"] == "error"


def test_install_ai_tools_alias_is_not_available() -> None:
    result = run_cli("install-ai-tools", "--json")

    assert result.returncode != 0
    assert "invalid choice" in result.stderr


def test_hf_snapshot_download_uses_mirror_workers_and_resume(tmp_path, monkeypatch) -> None:
    captured = {}

    def fake_snapshot_download(
        repo_id,
        repo_type=None,
        local_dir=None,
        allow_patterns=None,
        max_workers=8,
        endpoint=None,
        resume_download=False,
        local_dir_use_symlinks="auto",
    ):
        captured.update(
            {
                "repo_id": repo_id,
                "repo_type": repo_type,
                "local_dir": local_dir,
                "allow_patterns": allow_patterns,
                "max_workers": max_workers,
                "endpoint": endpoint,
                "resume_download": resume_download,
                "local_dir_use_symlinks": local_dir_use_symlinks,
            }
        )
        Path(str(local_dir)).mkdir(parents=True, exist_ok=True)
        return local_dir

    monkeypatch.setitem(
        sys.modules,
        "huggingface_hub",
        types.SimpleNamespace(snapshot_download=fake_snapshot_download),
    )
    monkeypatch.setenv("HF_ENDPOINT", "https://hf-mirror.com/")
    monkeypatch.setenv("FH_RADIO_STUDIO_HF_DOWNLOAD_WORKERS", "12")
    monkeypatch.delenv("HF_XET_HIGH_PERFORMANCE", raising=False)

    local_dir = tmp_path / "models" / "mert" / "repo"
    result = hf_download.download_hf_snapshot(
        repo_id="owner/model",
        local_dir=local_dir,
        allow_patterns=["*.json"],
    )

    assert result == local_dir
    assert captured["endpoint"] == "https://hf-mirror.com"
    assert captured["max_workers"] == 12
    assert captured["resume_download"] is True
    assert captured["local_dir_use_symlinks"] is False
    assert captured["local_dir"] == str(local_dir)
    assert captured["allow_patterns"] == ["*.json"]
    assert captured["repo_type"] == "model"
    assert sys.modules["huggingface_hub"].snapshot_download is fake_snapshot_download
    assert hf_download.hf_endpoint() == "https://hf-mirror.com"
    assert hf_download.hf_download_workers() == 12
    assert os.environ["HF_XET_HIGH_PERFORMANCE"] == "1"


def test_songformer_detects_replaceable_repo_dir(tmp_path) -> None:
    repo = tmp_path / "models" / "songformer" / "repo"
    _write_songformer_repo(repo)

    assert songformer._ready_repo_dir(tmp_path / "models") == repo


def test_songformer_deletes_invalid_preferred_repo_before_redownload(tmp_path, monkeypatch) -> None:
    model_dir = tmp_path / "models"
    repo = model_dir / "songformer" / "repo"
    repo.mkdir(parents=True)
    (repo / "stale.txt").write_text("bad", encoding="utf-8")

    def fake_download(target_model_dir):
        assert target_model_dir == model_dir
        assert not (repo / "stale.txt").exists()
        _write_songformer_repo(repo)
        return repo

    monkeypatch.setattr(songformer, "_download_repo", fake_download)

    assert songformer._ensure_repo(model_dir) == repo
    assert songformer._ready_repo_dir(model_dir) == repo


def test_mert_detects_replaceable_repo_dir(tmp_path) -> None:
    repo = tmp_path / "models" / "mert" / "repo"
    _write_mert_repo(repo)

    assert mert._ready_repo_dir(tmp_path / "models") == repo


def test_mert_deletes_invalid_preferred_repo_before_redownload(tmp_path, monkeypatch) -> None:
    model_dir = tmp_path / "models"
    repo = model_dir / "mert" / "repo"
    repo.mkdir(parents=True)
    (repo / "stale.txt").write_text("bad", encoding="utf-8")

    def fake_download(target_model_dir):
        assert target_model_dir == model_dir
        assert not (repo / "stale.txt").exists()
        _write_mert_repo(repo)
        return repo

    monkeypatch.setattr(mert, "_download_repo", fake_download)

    assert mert._ensure_repo(model_dir) == repo
    assert mert._ready_repo_dir(model_dir) == repo


def _write_songformer_repo(repo) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    (repo / "config.json").write_text("{}", encoding="utf-8")
    (repo / "modeling_songformer.py").write_text("# mock\n", encoding="utf-8")
    (repo / "model.safetensors").write_bytes(b"mock")
    musicfm = repo / "musicfm" / "model"
    musicfm.mkdir(parents=True, exist_ok=True)
    (musicfm / "mock.py").write_text("# mock\n", encoding="utf-8")


def _write_mert_repo(repo) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    (repo / "config.json").write_text("{}", encoding="utf-8")
    (repo / "preprocessor_config.json").write_text("{}", encoding="utf-8")
    (repo / "pytorch_model.bin").write_bytes(b"mock")
