from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

from backend.fh_radio_studio_cli.migration import migrate_project_paths
from backend.fh_radio_studio_cli.package import (
    load_playlist_plan_builtin_targets,
    load_playlist_plan_groups,
)
from backend.fh_radio_studio_cli.project_refs import track_key_for_project_path


def test_migrate_project_paths_rewrites_010_durable_project_json(tmp_path: Path) -> None:
    project = tmp_path / "project"
    external_game = tmp_path / "external-game"
    external_audio = external_game / "media" / "audio"
    external_strings = external_game / "media" / "Stripped" / "StringTables"
    source = project / "sources" / "Song.wav"
    siren = project / "siren" / "MSR-1.wav"
    package_manifest = (
        project / "packages" / "current" / "package" / "fh_radio_studio_package_manifest.json"
    )
    stdin_package_manifest = (
        project / "packages" / "pending" / "package" / "fh_radio_studio_package_manifest.json"
    )
    baseline_manifest = project / "backups" / "baseline-current" / "baseline_manifest.json"
    bank_order = project / "backups" / "baseline-current" / "derived" / "bank_order.json"
    last_applied = project / ".fh-radio-studio" / "last_applied_package_manifest.json"
    metadata = project / ".fh-radio-studio" / "track_metadata.json"
    timing = project / "analysis" / "track_timing.json"
    build_timing = project / "analysis" / "build_timing_manifest.json"
    siren_json = project / "siren" / "siren_imports.json"
    playlist = project / ".fh-radio-studio" / "playlist_plan.json"
    project_json = project / ".fh-radio-studio" / "project.json"
    external_track = external_game / "music" / "Outside.wav"
    external_bank = external_audio / "FMODBanks" / "R4_Tracks.bank"
    external_radio_info = external_audio / "RadioInfo_CN.xml"
    external_source_table = external_strings / "CHS.zip"
    external_target_table = external_strings / "EN.zip"

    for path in (
        source,
        siren,
        project / ".fh-radio-studio" / "artwork" / "cover.png",
        project / "analysis" / "track_timing.json",
        project / "analysis" / "build_timing_manifest.json",
        project / "packages" / "current" / "work" / "prepared" / "1.wav",
        project / "packages" / "current" / "work" / "stage" / "1.wav",
        project / "packages" / "current" / "package" / "media" / "audio" / "RadioInfo_CN.xml",
        project
        / "packages"
        / "current"
        / "package"
        / "media"
        / "Stripped"
        / "StringTables"
        / "EN.zip",
        project / "backups" / "baseline-current" / "media" / "audio" / "RadioInfo_CN.xml",
        project
        / "backups"
        / "baseline-current"
        / "media"
        / "audio"
        / "FMODBanks"
        / "R4_Tracks.bank",
        external_track,
        external_bank,
        external_radio_info,
        external_source_table,
        external_target_table,
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")

    _write_json(
        project_json,
        {
            "schema": 1,
            "app": "FH Radio Studio",
            "settings": {
                "game_dir": str(external_game),
                "preferred_path": str(external_target_table),
            },
        },
    )
    _write_json(
        metadata,
        {
            "schema_version": 1,
            "tracks": [
                {
                    "source": str(source),
                    "path_key": "legacy-source-key",
                    "artist": "A",
                    "title": "T",
                    "cover_art_path": str(project / ".fh-radio-studio" / "artwork" / "cover.png"),
                    "loudness_analysis": {
                        "source": str(source),
                        "integrated_lufs": -14.0,
                    },
                },
                {
                    "source": str(external_track),
                    "path_key": "legacy-external-key",
                    "artist": "External",
                    "title": "Outside",
                },
            ],
        },
    )
    _write_json(
        timing,
        {
            "schema_version": 1,
            "tracks": [
                {"source": str(source), "path_key": "legacy-source-key", "bpm": 120},
                {"source": str(external_track), "path_key": "legacy-external-key", "bpm": 90},
            ],
        },
    )
    _write_json(
        build_timing,
        {
            "schema_version": 1,
            "tracks": [
                {"source": str(source), "path_key": "legacy-source-key", "markers_sec": {}},
            ],
        },
    )
    _write_json(
        siren_json,
        {
            "schema_version": 1,
            "tracks": [
                {"path": str(siren), "path_key": "legacy-siren-key", "cid": "1", "title": "S"},
            ],
        },
    )
    _write_json(
        playlist,
        {
            "schema_version": 1,
            "assignments": [
                {
                    "source": str(source),
                    "radio_code": "XS",
                    "playlistType": "Event",
                    "slot": 1,
                },
            ],
            "builtin_targets": [
                "HOR|Event",
                {"radioCode": "XS", "playlistType": "FreeRoam"},
            ],
        },
    )
    _write_json(
        package_manifest,
        {
            "schema_version": 1,
            "game_dir": str(external_game),
            "source_audio_dir": str(project / "backups" / "baseline-current" / "media" / "audio"),
            "source_radio_info": str(
                project / "backups" / "baseline-current" / "media" / "audio" / "RadioInfo_CN.xml"
            ),
            "source_bank": str(
                project
                / "backups"
                / "baseline-current"
                / "media"
                / "audio"
                / "FMODBanks"
                / "R4_Tracks.bank"
            ),
            "radio_code": "XS",
            "playlist_plan": str(playlist),
            "timing_manifest": str(build_timing),
            "baseline_manifest": str(baseline_manifest),
            "baseline_completion": {
                "baseline_manifest": str(baseline_manifest),
            },
            "language": {
                "source_string_tables_dir": str(external_strings),
                "source_table": str(external_source_table),
                "target_table": str(external_target_table),
                "packaged_table": str(
                    project
                    / "packages"
                    / "current"
                    / "package"
                    / "media"
                    / "Stripped"
                    / "StringTables"
                    / "EN.zip"
                ),
            },
            "radios": [
                {
                    "radio_code": "XS",
                    "source_bank": str(
                        project
                        / "backups"
                        / "baseline-current"
                        / "media"
                        / "audio"
                        / "FMODBanks"
                        / "R4_Tracks.bank"
                    ),
                    "music": [
                        {
                            "source": str(source),
                            "path_key": "legacy-source-key",
                            "prepared_wav": str(
                                project / "packages" / "current" / "work" / "prepared" / "1.wav"
                            ),
                        }
                    ],
                    "assignments": [
                        {
                            "source_index": 0,
                            "path_key": "legacy-source-key",
                            "radioCode": "XS",
                            "playlistType": "Event",
                            "staged_wav": str(
                                project / "packages" / "current" / "work" / "stage" / "1.wav"
                            ),
                        }
                    ],
                }
            ],
            "package_files": [
                {
                    "path": str(
                        project
                        / "packages"
                        / "current"
                        / "package"
                        / "media"
                        / "audio"
                        / "RadioInfo_CN.xml"
                    )
                }
            ],
        },
    )
    _write_json(
        stdin_package_manifest,
        {
            "schema_version": 2,
            "playlist_plan": "-",
            "timing_manifest": str(build_timing),
            "radios": [],
        },
    )
    _write_json(
        baseline_manifest,
        {
            "schema_version": 1,
            "game_dir": str(external_game),
            "audio_dir": str(external_audio),
            "package_audio": str(project / "packages" / "current" / "package" / "media" / "audio"),
            "files": [
                {
                    "source_game_path": str(external_bank),
                    "backup_path": str(
                        project
                        / "backups"
                        / "baseline-current"
                        / "media"
                        / "audio"
                        / "FMODBanks"
                        / "R4_Tracks.bank"
                    ),
                    "package_path": str(
                        project
                        / "packages"
                        / "current"
                        / "package"
                        / "media"
                        / "audio"
                        / "FMODBanks"
                        / "R4_Tracks.bank"
                    ),
                }
            ],
        },
    )
    _write_json(
        bank_order,
        {
            "schema_version": 1,
            "source_baseline_manifest": str(baseline_manifest),
            "source_radio_info": "media/audio/RadioInfo_CN.xml",
        },
    )
    _write_json(
        last_applied,
        {
            "schema_version": 1,
            "source_package_manifest": str(package_manifest),
            "package_root": str(package_manifest.parent),
            "radios": [
                {
                    "radio": 4,
                    "radio_code": "XS",
                    "music": [
                        {
                            "source": str(source),
                            "path_key": "legacy-source-key",
                        }
                    ],
                    "assignments": [
                        {
                            "source_index": 0,
                            "path_key": "legacy-source-key",
                            "playlistType": "Event",
                            "playlist_entry": True,
                        }
                    ],
                }
            ],
            "package_files": [{"install_relative_path": "media/audio/RadioInfo_CN.xml"}],
        },
    )

    assert migrate_project_paths(project) > 0

    track_key = track_key_for_project_path(project, source)
    siren_key = track_key_for_project_path(project, siren)
    assert track_key is not None
    assert siren_key is not None

    migrated_metadata = _read_json(metadata)
    tracks_by_key = {
        item["track_key"]: item
        for item in migrated_metadata["tracks"]
        if isinstance(item, dict) and item.get("track_key")
    }
    assert tracks_by_key[track_key]["source_ref"] == "fh-project:/sources/Song.wav"
    assert "source" not in tracks_by_key[track_key]
    assert "path_key" not in tracks_by_key[track_key]
    assert (
        tracks_by_key[track_key]["cover_art_path"]
        == "fh-project:/.fh-radio-studio/artwork/cover.png"
    )
    assert "source" not in tracks_by_key[track_key]["loudness_analysis"]
    assert tracks_by_key[siren_key]["source_ref"] == "fh-project:/siren/MSR-1.wav"
    external_metadata = next(
        item for item in migrated_metadata["tracks"] if item.get("title") == "Outside"
    )
    assert external_metadata["source"] == str(external_track)
    assert external_metadata["path_key"] == "legacy-external-key"

    migrated_timing = _read_json(timing)
    assert migrated_timing["tracks"][0] == {"track_key": track_key, "bpm": 120}
    assert migrated_timing["tracks"][1]["source"] == str(external_track)
    assert migrated_timing["tracks"][1]["path_key"] == "legacy-external-key"
    assert _read_json(build_timing)["tracks"][0] == {
        "track_key": track_key,
        "markers_sec": {},
    }
    assert _read_json(siren_json)["tracks"][0] == {
        "track_key": siren_key,
        "cid": "1",
        "title": "S",
    }
    migrated_assignment = _read_json(playlist)["assignments"][0]
    assert migrated_assignment["track_key"] == track_key
    assert migrated_assignment["radio_code"] == "R4"
    assert migrated_assignment["playlist_type"] == "Event"
    assert "playlistType" not in migrated_assignment
    assert "source" not in migrated_assignment
    assert _read_json(playlist)["builtin_targets"] == [
        {"radio_code": "R1", "playlist_type": "Event"},
        {"radio_code": "R4", "playlist_type": "FreeRoam"},
    ]

    migrated_package = _read_json(package_manifest)
    assert migrated_package["game_dir"] == str(external_game)
    assert (
        migrated_package["source_audio_dir"] == "fh-project:/backups/baseline-current/media/audio"
    )
    assert migrated_package["source_radio_info"] == (
        "fh-project:/backups/baseline-current/media/audio/RadioInfo_CN.xml"
    )
    assert migrated_package["source_bank"] == (
        "fh-project:/backups/baseline-current/media/audio/FMODBanks/R4_Tracks.bank"
    )
    assert migrated_package["radio_code"] == "R4"
    assert migrated_package["playlist_plan"] == "fh-project:/.fh-radio-studio/playlist_plan.json"
    assert migrated_package["timing_manifest"] == "fh-project:/analysis/build_timing_manifest.json"
    assert migrated_package["baseline_manifest"] == (
        "fh-project:/backups/baseline-current/baseline_manifest.json"
    )
    assert migrated_package["baseline_completion"]["baseline_manifest"] == (
        "fh-project:/backups/baseline-current/baseline_manifest.json"
    )
    assert migrated_package["language"]["source_table"] == str(external_source_table)
    assert migrated_package["language"]["target_table"] == str(external_target_table)
    assert migrated_package["language"]["packaged_table"] == (
        "fh-project:/packages/current/package/media/Stripped/StringTables/EN.zip"
    )
    radio = migrated_package["radios"][0]
    assert radio["source_bank"] == (
        "fh-project:/backups/baseline-current/media/audio/FMODBanks/R4_Tracks.bank"
    )
    assert radio["radio_code"] == "R4"
    assert radio["music"][0]["track_key"] == track_key
    assert "source" not in radio["music"][0]
    assert "path_key" not in radio["music"][0]
    assert radio["music"][0]["prepared_wav"] == "fh-project:/packages/current/work/prepared/1.wav"
    assert radio["assignments"][0]["track_key"] == track_key
    assert radio["assignments"][0]["radio_code"] == "R4"
    assert radio["assignments"][0]["playlist_type"] == "Event"
    assert "radioCode" not in radio["assignments"][0]
    assert "playlistType" not in radio["assignments"][0]
    assert "source" not in radio["assignments"][0]
    assert "path_key" not in radio["assignments"][0]
    assert radio["assignments"][0]["staged_wav"] == "fh-project:/packages/current/work/stage/1.wav"
    assert migrated_package["package_files"][0]["path"] == (
        "fh-project:/packages/current/package/media/audio/RadioInfo_CN.xml"
    )
    migrated_stdin_package = _read_json(stdin_package_manifest)
    assert migrated_stdin_package["playlist_plan"] == "-"
    assert migrated_stdin_package["timing_manifest"] == (
        "fh-project:/analysis/build_timing_manifest.json"
    )

    migrated_baseline = _read_json(baseline_manifest)
    assert migrated_baseline["game_dir"] == str(external_game)
    assert migrated_baseline["audio_dir"] == str(external_audio)
    assert migrated_baseline["package_audio"] == (
        "fh-project:/packages/current/package/media/audio"
    )
    assert migrated_baseline["files"][0]["source_game_path"] == str(external_bank)
    assert migrated_baseline["files"][0]["backup_path"] == (
        "fh-project:/backups/baseline-current/media/audio/FMODBanks/R4_Tracks.bank"
    )
    assert migrated_baseline["files"][0]["package_path"] == (
        "fh-project:/packages/current/package/media/audio/FMODBanks/R4_Tracks.bank"
    )

    migrated_bank_order = _read_json(bank_order)
    assert migrated_bank_order["source_baseline_manifest"] == (
        "fh-project:/backups/baseline-current/baseline_manifest.json"
    )
    assert migrated_bank_order["source_radio_info"] == "media/audio/RadioInfo_CN.xml"
    migrated_last_applied = _read_json(last_applied)
    assert migrated_last_applied["source_package_manifest"] == (
        "fh-project:/packages/current/package/fh_radio_studio_package_manifest.json"
    )
    assert migrated_last_applied["package_root"] == "fh-project:/packages/current/package"
    assert migrated_last_applied["radios"][0]["radio_code"] == "R4"
    assert migrated_last_applied["radios"][0]["music"][0]["track_key"] == track_key
    assert "source" not in migrated_last_applied["radios"][0]["music"][0]
    assert migrated_last_applied["radios"][0]["assignments"][0]["track_key"] == track_key
    assert migrated_last_applied["radios"][0]["assignments"][0]["playlist_type"] == "Event"
    assert "playlistType" not in migrated_last_applied["radios"][0]["assignments"][0]
    assert "source" not in migrated_last_applied["radios"][0]["assignments"][0]

    migrated_project = _read_json(project_json)
    assert migrated_project["schema"] == 2
    assert migrated_project["path_schema"] == 2
    assert migrated_project["current_project_dir"] == str(project.resolve())
    assert migrated_project["settings"]["game_dir"] == str(external_game)
    assert migrated_project["settings"]["preferred_path"] == str(external_target_table)


def test_migrated_playlist_plan_is_runtime_file_contract(tmp_path: Path) -> None:
    project = tmp_path / "project"
    source = project / "sources" / "Song.wav"
    playlist = project / ".fh-radio-studio" / "playlist_plan.json"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not-a-real-wav")
    _write_json(
        playlist,
        {
            "schema_version": 2,
            "assignments": [
                {
                    "source": str(source),
                    "radioCode": "XS",
                    "playlistType": "Event",
                    "slot": 2,
                }
            ],
            "builtin_targets": [
                "HOR|FreeRoam",
                {"radioCode": "XS", "playlistType": "Event"},
            ],
        },
    )

    assert migrate_project_paths(project) > 0

    migrated = _read_json(playlist)
    assert migrated["assignments"] == [
        {
            "track_key": track_key_for_project_path(project, source),
            "radio_code": "R4",
            "playlist_type": "Event",
            "slot": 2,
        }
    ]
    assert migrated["builtin_targets"] == [
        {"radio_code": "R1", "playlist_type": "FreeRoam"},
        {"radio_code": "R4", "playlist_type": "Event"},
    ]

    root = ET.fromstring("""
        <RadioInfo>
          <RadioStations>
            <RadioStation Number="1" Name="Horizon Pulse" />
            <RadioStation Number="4" Name="Horizon XS" />
          </RadioStations>
        </RadioInfo>
        """)
    assert load_playlist_plan_builtin_targets(str(playlist), root) == [
        {"radio": 1, "playlist_types": ["FreeRoam"]},
        {"radio": 4, "playlist_types": ["Event"]},
    ]
    groups = load_playlist_plan_groups(str(playlist), root, project_dir=project)
    assert len(groups) == 1
    assert groups[0]["radio"] == 4
    assert groups[0]["sources"] == [source]
    source_key = next(iter(groups[0]["playlist_types_by_source"]))
    assert groups[0]["playlist_types_by_source"][source_key] == ["Event"]
    assert groups[0]["playlist_slots_by_source"][source_key] == {"Event": 2}


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))
