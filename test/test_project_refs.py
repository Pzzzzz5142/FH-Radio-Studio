from __future__ import annotations

from pathlib import Path

import pytest

from backend.fh_radio_studio_cli.project_json_guard import (
    ProjectJsonPathSchemaError,
    find_project_json_path_violations,
    write_project_json,
)
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


def test_project_json_guard_catches_project_owned_absolute_paths(tmp_path: Path) -> None:
    project = tmp_path / "project"
    source = project / "siren" / "MSR-306877.wav"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"")

    violations = find_project_json_path_violations(
        project,
        {
            "tracks": [
                {
                    "track_key": "trkref_ok",
                    "loudness_analysis": {"source": str(source)},
                }
            ]
        },
    )

    assert len(violations) == 1
    assert violations[0].pointer == "/tracks/0/loudness_analysis/source"
    assert violations[0].field == "source"
    assert violations[0].value == str(source)


def test_project_json_guard_allows_external_absolute_paths(tmp_path: Path) -> None:
    project = tmp_path / "project"
    source = tmp_path / "game" / "media" / "audio" / "FMODBanks" / "R4.bank"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"")

    violations = find_project_json_path_violations(
        project,
        {
            "files": [
                {
                    "source_game_path": str(source),
                    "source": str(source),
                }
            ]
        },
    )

    assert violations == []


def test_project_json_writer_rejects_invalid_project_ref_before_writing(
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    output = project / "analysis" / "bad.json"

    with pytest.raises(ProjectJsonPathSchemaError):
        write_project_json(
            output,
            {"tracks": [{"path": "fh-project:/sources/../bad.wav"}]},
            project_dir=project,
        )

    assert not output.exists()
