from __future__ import annotations

import argparse

from backend.fh_radio_studio_cli.audio import build_markers


def test_build_markers_fills_dj_lite_end_cues() -> None:
    sr = 48000
    total_samples = 10 * sr

    markers = build_markers(
        argparse.Namespace(),
        {
            "TrackDrop": 0,
            "PostDrop": 5 * sr,
            "TrackLoopStart": 0,
            "TrackLoopEnd": total_samples - 1,
            "PostRaceLoopStart": 5 * sr,
            "PostRaceLoopEnd": total_samples - 1,
        },
        total_samples,
        sr,
    )

    assert markers["End"] == total_samples - 1
    assert markers["StingerStart"] == 7 * sr
    assert markers["DJStart"] == 8 * sr
    assert markers["DJDrop"] == -1
    assert markers["DJSegment"] == -1


def test_build_markers_keeps_dj_lite_safe_for_short_audio() -> None:
    sr = 48000
    total_samples = 1 * sr

    markers = build_markers(
        argparse.Namespace(),
        {
            "TrackDrop": 0,
            "PostDrop": total_samples - 1,
            "TrackLoopStart": 0,
            "TrackLoopEnd": total_samples - 1,
            "PostRaceLoopStart": 0,
            "PostRaceLoopEnd": total_samples - 1,
        },
        total_samples,
        sr,
    )

    assert 0 <= markers["StingerStart"] <= markers["End"]
    assert 0 <= markers["DJStart"] <= markers["End"]
