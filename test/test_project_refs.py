from __future__ import annotations

from pathlib import Path

import pytest

from backend.fh_radio_studio_cli.project_refs import (
    ProjectRefError,
    normalize_project_ref,
    project_ref_for_path,
    resolve_project_ref,
    track_key_for_source_ref,
)


def test_project_ref_round_trips_project_owned_path(tmp_path: Path) -> None:
    project = tmp_path / "project"
    track = project / "sources" / "Folder A" / "100% ready #1.wav"
    track.parent.mkdir(parents=True)
    track.write_bytes(b"")

    source_ref = project_ref_for_path(project, track)

    assert source_ref == "fh-project:/sources/Folder%20A/100%25%20ready%20%231.wav"
    assert resolve_project_ref(project, source_ref) == track.resolve()


def test_project_ref_keeps_external_paths_external(tmp_path: Path) -> None:
    project = tmp_path / "project"
    outside = tmp_path / "external" / "song.wav"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"")

    assert project_ref_for_path(project, outside) is None


def test_project_ref_rejects_escape_and_non_project_roots() -> None:
    invalid = [
        "fh-project:/sources/../song.wav",
        "fh-project://sources/song.wav",
        "fh-project:/tmp/song.wav",
        "fh-project:/sources/C:/song.wav",
        "fh-project:/sources/foo%2Fbar.wav",
        "fh-project:/sources/bad%zz.wav",
        "fh-project:/sources/bad%00name.wav",
    ]

    for source_ref in invalid:
        with pytest.raises(ProjectRefError):
            normalize_project_ref(source_ref)


def test_track_key_is_derived_from_canonical_source_ref() -> None:
    left = track_key_for_source_ref("fh-project:/sources/./Song.wav")
    right = track_key_for_source_ref("fh-project:/sources/Song.wav")

    assert left == right
    assert left.startswith("trkref_")
    assert len(left) == len("trkref_") + 32
