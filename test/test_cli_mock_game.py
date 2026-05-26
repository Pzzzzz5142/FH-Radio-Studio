from __future__ import annotations

import json
import shutil
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

from conftest import assert_cli_ok, md5_file, run_cli, write_test_tone

from tools.test.create_mock_game import FH6_STEAM_APP_ID, MOCK_TRACKS, build_mock_fsb5


def test_probe_reads_mock_game_directory(mock_game) -> None:
    result = run_cli("probe", "--game-dir", str(mock_game.game_dir))

    assert_cli_ok(result)
    assert "RadioInfo: 2 file(s)" in result.stdout
    assert "FMODBanks: 1 track bank(s)" in result.stdout
    assert "XML   Bank" in result.stdout
    assert "R4   Horizon XS" in result.stdout
    assert "R4_Tracks_CU1" in result.stdout


def test_status_json_reports_mock_radio_and_language_slots(mock_game) -> None:
    result = run_cli(
        "status",
        "--game-dir",
        str(mock_game.game_dir),
        "--preferred-path",
        str(mock_game.preferred_path),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["preferred_lang"] == "EN"
    assert payload["selected_radio"]["number"] == 4
    assert payload["selected_radio"]["name"] == "Horizon XS"
    assert payload["selected_radio"]["tracks"] == 3
    assert payload["selected_radio"]["bank_slots"] == 3
    assert payload["selected_radio"]["target_bank_name"] == "R4_Tracks_CU1"
    assert payload["selected_radio"]["playlists"]["FreeRoam"] == 3
    assert payload["language"]["target_lang"] == "EN"
    assert payload["language"]["available"] == ["CHS", "EN", "JP"]
    assert payload["language"]["target_exists"] is True


def test_status_prefers_parseable_bank_slots_over_extra_xml_tracks(mock_game) -> None:
    radio_info = mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml"
    tree = ET.parse(radio_info)
    station = tree.getroot().find(".//RadioStation[@Number='4']")
    assert station is not None
    track_list = station.find("./SampleList[@Type='Track']")
    assert track_list is not None
    ET.SubElement(
        track_list,
        "Sample",
        {
            "SoundName": "HZ6_R4_XML_ONLY",
            "SampleLength": "48000",
            "SampleRate": "48000",
            "DisplayName": "XML Only",
            "Artist": "FH Radio Studio Dev",
        },
    )
    tree.write(radio_info, encoding="utf-8", xml_declaration=True)

    result = run_cli(
        "status",
        "--game-dir",
        str(mock_game.game_dir),
        "--preferred-path",
        str(mock_game.preferred_path),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--json",
    )

    assert_cli_ok(result)
    selected = json.loads(result.stdout)["selected_radio"]
    assert selected["tracks"] == 4
    assert selected["bank_slots"] == 3
    assert selected["replaceable_slots"] == 3
    assert selected["target_bank_name"] == "R4_Tracks_CU1"


def test_baseline_plan_json_includes_versioned_mock_files(mock_game) -> None:
    result = run_cli(
        "baseline",
        "plan",
        "--game-dir",
        str(mock_game.game_dir),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["game_version_id"] == "steam-b99000001"
    assert payload["file_count"] == 6
    assert payload["by_scope"]["radio_info"] == 2
    assert payload["by_scope"]["radio_bank"] == 1
    assert payload["by_scope"]["string_table"] == 3
    install_paths = {item["install_relative_path"] for item in payload["files"]}
    assert "media/audio/RadioInfo_CN.xml" in install_paths
    assert "media/audio/RadioInfo_EN.xml" in install_paths
    assert "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank" in install_paths
    assert "media/Stripped/StringTables/CHS.zip" in install_paths
    assert all(item["baseline_status"] == "not_backed_up" for item in payload["files"])


def test_baseline_plan_emits_parallel_hash_progress(mock_game) -> None:
    result = run_cli(
        "baseline",
        "plan",
        "--game-dir",
        str(mock_game.game_dir),
        "--jobs",
        "2",
        "--progress-jsonl",
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    assert payload["file_count"] == 6
    progress_prefix = "FH_RADIO_STUDIO_PROGRESS "
    events = [
        json.loads(line[len(progress_prefix) :])
        for line in result.stderr.splitlines()
        if line.startswith(progress_prefix)
    ]
    assert any(event.get("event") == "plan" for event in events)
    assert any(
        event.get("event") == "step_started"
        and event.get("step_id") == "baseline.hash"
        and event.get("jobs") == 2
        for event in events
    )
    completed = [event for event in events if event.get("event") == "hash_completed"]
    assert len(completed) == payload["file_count"]
    assert completed[-1]["completed_files"] == payload["file_count"]
    assert any(
        event.get("event") == "step_completed" and event.get("step_id") == "baseline.hash"
        for event in events
    )


def test_baseline_plan_and_status_resolve_moved_baseline_files(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    moved_dir = full_project.backups_dir / "moved-baseline-current"

    create = run_cli(
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
    assert_cli_ok(create)
    shutil.move(str(baseline_dir), str(moved_dir))
    moved_manifest = moved_dir / "baseline_manifest.json"

    plan = run_cli(
        "baseline",
        "plan",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(moved_manifest),
        "--json",
    )
    assert_cli_ok(plan)
    plan_payload = json.loads(plan.stdout)
    assert plan_payload["file_count"] == 6
    assert all(item["baseline_status"] == "ok" for item in plan_payload["files"])

    status = run_cli(
        "status",
        "--game-dir",
        str(mock_game.game_dir),
        "--preferred-path",
        str(mock_game.preferred_path),
        "--source",
        "CHS",
        "--target",
        "EN",
        "--baseline-manifest",
        str(moved_manifest),
        "--json",
    )
    assert_cli_ok(status)
    status_payload = json.loads(status.stdout)
    assert status_payload["language"]["voice_slot_verified"] is True
    assert status_payload["language"]["target_baseline"]["status"] == "ok"


def test_verify_integrity_reports_current_baseline_without_package(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    create = run_cli(
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
    assert_cli_ok(create)

    result = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    integrity = payload["integrity"]
    assert payload["kind"] == "file_integrity"
    assert payload["baseline_plan"]["file_count"] == 6
    assert integrity["level"] == "no_package"
    assert integrity["checked_files"] == 6
    assert integrity["baseline_matches"] == 6
    assert integrity["changed_files"] == 0


def test_verify_integrity_reports_package_applied_from_cli(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    create = run_cli(
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
    assert_cli_ok(create)

    package_root = full_project.packages_dir / "single-radioinfo" / "package"
    package_file = package_root / "media" / "audio" / "RadioInfo_CN.xml"
    package_file.parent.mkdir(parents=True, exist_ok=True)
    package_file.write_text('<RadioInfo package="applied" />\n', encoding="utf-8")
    shutil.copy2(package_file, mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml")
    package_manifest = {
        "schema_version": 2,
        "kind": "fh_radio_studio_package",
        "package_files": [
            {
                "kind": "audio",
                "relative_path": "RadioInfo_CN.xml",
                "install_relative_path": "media/audio/RadioInfo_CN.xml",
                "path": str(package_file),
                "size": package_file.stat().st_size,
                "md5": md5_file(package_file),
            }
        ],
    }
    (package_root / "fh_radio_studio_package_manifest.json").write_text(
        json.dumps(package_manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    result = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(package_root),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--jobs",
        "2",
        "--progress-jsonl",
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    integrity = payload["integrity"]
    assert integrity["level"] == "package_applied"
    assert integrity["checked_files"] == 1
    assert integrity["package_matches"] == 1
    assert integrity["baseline_matches"] == 0
    plan_file = next(
        item
        for item in payload["baseline_plan"]["files"]
        if item["install_relative_path"] == "media/audio/RadioInfo_CN.xml"
    )
    assert plan_file["coverage_status"] == "covered"
    assert plan_file["package_diff_status"] == "modified"
    assert plan_file["package_md5"] == md5_file(package_file)
    progress_prefix = "FH_RADIO_STUDIO_PROGRESS "
    events = [
        json.loads(line[len(progress_prefix) :])
        for line in result.stderr.splitlines()
        if line.startswith(progress_prefix)
    ]
    assert any(
        event.get("event") == "step_started"
        and event.get("step_id") == "baseline.hash"
        and event.get("jobs") == 2
        for event in events
    )


def test_verify_integrity_uses_package_baseline_diff_for_target_consistency(
    mock_game, full_project
) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    create = run_cli(
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
    assert_cli_ok(create)

    package_root = full_project.packages_dir / "mixed-prepared-package" / "package"
    package_audio = package_root / "media" / "audio"
    unchanged = package_audio / "RadioInfo_CN.xml"
    changed = package_audio / "RadioInfo_EN.xml"
    unchanged.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml", unchanged)
    changed.write_text('<RadioInfo changed="true" />\n', encoding="utf-8")
    package_manifest = {
        "schema_version": 2,
        "kind": "fh_radio_studio_package",
        "package_files": [
            {
                "kind": "audio",
                "relative_path": "RadioInfo_CN.xml",
                "install_relative_path": "media/audio/RadioInfo_CN.xml",
                "path": str(unchanged),
                "size": unchanged.stat().st_size,
                "md5": md5_file(unchanged),
            },
            {
                "kind": "audio",
                "relative_path": "RadioInfo_EN.xml",
                "install_relative_path": "media/audio/RadioInfo_EN.xml",
                "path": str(changed),
                "size": changed.stat().st_size,
                "md5": md5_file(changed),
            },
        ],
    }
    (package_root / "fh_radio_studio_package_manifest.json").write_text(
        json.dumps(package_manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    result = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(package_root),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--json",
    )

    assert_cli_ok(result)
    payload = json.loads(result.stdout)
    integrity = payload["integrity"]
    assert integrity["level"] == "baseline"
    assert integrity["checked_files"] == 2
    assert integrity["package_files"] == 2
    assert integrity["package_matches"] == 1
    assert integrity["baseline_matches"] == 2
    assert integrity["changed_files"] == 0
    by_path = {item["install_relative_path"]: item for item in payload["baseline_plan"]["files"]}
    assert by_path["media/audio/RadioInfo_CN.xml"]["package_diff_status"] == "unchanged"
    assert by_path["media/audio/RadioInfo_CN.xml"]["coverage_status"] == "original"
    assert by_path["media/audio/RadioInfo_EN.xml"]["package_diff_status"] == "modified"
    assert by_path["media/audio/RadioInfo_EN.xml"]["coverage_status"] == "original"

    (mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml").write_text(
        '<RadioInfo official_update="true" />\n',
        encoding="utf-8",
    )
    after_unmodified_file_changed = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(package_root),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--json",
    )

    assert_cli_ok(after_unmodified_file_changed)
    payload = json.loads(after_unmodified_file_changed.stdout)
    integrity = payload["integrity"]
    assert integrity["level"] == "external_conflict"
    assert integrity["checked_files"] == 2
    assert integrity["package_matches"] == 0
    assert integrity["baseline_matches"] == 1
    assert integrity["changed_files"] == 1
    by_path = {item["install_relative_path"]: item for item in payload["baseline_plan"]["files"]}
    assert (
        by_path["media/audio/RadioInfo_CN.xml"]["baseline_status"] == "backup_differs_from_current"
    )
    assert by_path["media/audio/RadioInfo_CN.xml"]["coverage_status"] == "changed"


def test_verify_integrity_reports_previous_package_applied(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    create = run_cli(
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
    assert_cli_ok(create)

    current_package_root = full_project.packages_dir / "current" / "package"
    current_package_audio = current_package_root / "media" / "audio"
    current_package_xml = current_package_audio / "RadioInfo_CN.xml"
    current_package_xml.parent.mkdir(parents=True, exist_ok=True)
    current_package_xml.write_text('<RadioInfo prepared="v2" />\n', encoding="utf-8")
    (current_package_root / "fh_radio_studio_package_manifest.json").write_text(
        json.dumps(
            {
                "schema_version": 2,
                "kind": "fh_radio_studio_package",
                "game_version_id": "steam-b99000001",
                "package_files": [
                    {
                        "relative_path": "RadioInfo_CN.xml",
                        "install_relative_path": "media/audio/RadioInfo_CN.xml",
                        "size": current_package_xml.stat().st_size,
                        "md5": md5_file(current_package_xml),
                    }
                ],
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    game_xml = mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml"
    game_xml.write_text('<RadioInfo prepared="v1" />\n', encoding="utf-8")
    last_applied = full_project.metadata_dir / "last_applied_package_manifest.json"
    last_applied.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "kind": "last_applied_package",
                "game_version_id": "steam-b99000001",
                "package_files": [
                    {
                        "relative_path": "RadioInfo_CN.xml",
                        "install_relative_path": "media/audio/RadioInfo_CN.xml",
                        "size": game_xml.stat().st_size,
                        "md5": md5_file(game_xml),
                    }
                ],
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    result = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(full_project.packages_dir / "current"),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--last-applied-package-manifest",
        str(last_applied),
        "--json",
    )

    assert_cli_ok(result)
    integrity = json.loads(result.stdout)["integrity"]
    assert integrity["level"] == "previous_package_applied"
    assert integrity["last_applied_package_matches"] == 1
    assert integrity["package_matches"] == 0

    deploy = run_cli(
        "deploy-package",
        str(full_project.packages_dir / "current" / "package"),
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--last-applied-manifest",
        str(last_applied),
        "--yes",
    )

    assert_cli_ok(deploy)
    assert game_xml.read_text(encoding="utf-8") == current_package_xml.read_text(encoding="utf-8")
    updated_last_applied = json.loads(last_applied.read_text(encoding="utf-8"))
    assert updated_last_applied["package_files"][0]["md5"] == md5_file(current_package_xml)


def test_verify_integrity_offers_build_bump_when_files_match(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    create = run_cli(
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
    assert_cli_ok(create)
    steam_manifest = mock_game.root / "steamapps" / f"appmanifest_{FH6_STEAM_APP_ID}.acf"
    steam_manifest.write_text(
        steam_manifest.read_text(encoding="utf-8").replace(
            '"buildid" "99000001"', '"buildid" "99000002"'
        ),
        encoding="utf-8",
    )

    result = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--json",
    )
    assert_cli_ok(result)
    integrity = json.loads(result.stdout)["integrity"]
    assert integrity["level"] == "build_bump_available"
    assert integrity["baseline_build_compatible"] is False

    bumped = run_cli(
        "baseline",
        "bump-build",
        "--game-dir",
        str(mock_game.game_dir),
        "--manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--yes",
    )
    assert_cli_ok(bumped)
    payload = json.loads((baseline_dir / "baseline_manifest.json").read_text(encoding="utf-8"))
    assert payload["supported_game_version_ids"] == ["steam-b99000001", "steam-b99000002"]


def test_build_package_completes_deploy_set_from_baseline(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    package_dir = full_project.packages_dir / "complete-language-package"
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

    build = run_cli(
        "build-package",
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--baseline-manifest",
        str(baseline_dir / "baseline_manifest.json"),
        "--out-dir",
        str(package_dir),
    )

    assert_cli_ok(build)
    manifest = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    install_paths = {item["install_relative_path"] for item in manifest["package_files"]}
    assert manifest["baseline_completion"]["baseline_files"] == 6
    assert manifest["baseline_completion"]["copied_baseline_files"] == 2
    assert len(install_paths) == 6
    assert install_paths == {
        "media/audio/RadioInfo_CN.xml",
        "media/audio/RadioInfo_EN.xml",
        "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank",
        "media/Stripped/StringTables/CHS.zip",
        "media/Stripped/StringTables/EN.zip",
        "media/Stripped/StringTables/JP.zip",
    }
    assert md5_file(
        package_dir / "package" / "media" / "Stripped" / "StringTables" / "CHS.zip"
    ) == md5_file(mock_game.game_dir / "media" / "Stripped" / "StringTables" / "CHS.zip")
    assert md5_file(
        package_dir / "package" / "media" / "Stripped" / "StringTables" / "JP.zip"
    ) == md5_file(mock_game.game_dir / "media" / "Stripped" / "StringTables" / "JP.zip")


def test_baseline_promote_rewrites_backup_paths_after_move(mock_game, full_project) -> None:
    current_dir = full_project.backups_dir / "baseline-current"
    pending_dir = full_project.backups_dir / "baseline-pending-verify"
    old_root = full_project.backups_dir / "baseline-old"

    current = run_cli(
        "baseline",
        "create",
        "--game-dir",
        str(mock_game.game_dir),
        "--out-dir",
        str(current_dir),
        "--state",
        "current",
        "--yes",
    )
    assert_cli_ok(current)
    pending = run_cli(
        "baseline",
        "create",
        "--game-dir",
        str(mock_game.game_dir),
        "--out-dir",
        str(pending_dir),
        "--state",
        "pending-verify",
        "--yes",
    )
    assert_cli_ok(pending)

    promote = run_cli(
        "baseline",
        "promote",
        "--current-dir",
        str(current_dir),
        "--pending-dir",
        str(pending_dir),
        "--target-current-dir",
        str(current_dir),
        "--old-root",
        str(old_root),
        "--yes",
    )
    assert_cli_ok(promote)

    promoted_manifest = current_dir / "baseline_manifest.json"
    payload = json.loads(promoted_manifest.read_text(encoding="utf-8"))
    assert payload["state"] == "current"
    assert payload["file_count"] == 6
    for item in payload["files"]:
        backup_path = item["backup_path"]
        assert str(current_dir) in backup_path
        assert (current_dir / item["install_relative_path"]).exists()
        assert item["md5"] == md5_file(current_dir / item["install_relative_path"])


def test_baseline_promote_keeps_latest_five_old_build_ids(mock_game, full_project) -> None:
    current_dir = full_project.backups_dir / "baseline-current"
    pending_dir = full_project.backups_dir / "baseline-pending-verify"
    old_root = full_project.backups_dir / "baseline-old"

    def write_old_build(version_id: str, stamp: str) -> Path:
        old_dir = old_root / f"fh6-{version_id}-baseline-old-{stamp}"
        old_dir.mkdir(parents=True, exist_ok=True)
        archived_at = (
            f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]}"
            f"T{stamp[9:11]}:{stamp[11:13]}:{stamp[13:15]}+00:00"
        )
        (old_dir / "baseline_manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "game_baseline",
                    "game_version_id": version_id,
                    "archived_at": archived_at,
                    "files": [],
                }
            ),
            encoding="utf-8",
        )
        return old_dir

    removed_duplicate = write_old_build("steam-b11111111", "20000101_000000")
    removed_build = write_old_build("steam-b22222222", "20000102_000000")
    removed_older_build = write_old_build("steam-b33333333", "20000103_000000")
    kept_builds = [
        write_old_build("steam-b44444444", "20000104_000000"),
        write_old_build("steam-b55555555", "20000105_000000"),
        write_old_build("steam-b66666666", "20000106_000000"),
        write_old_build("steam-b11111111", "20000107_000000"),
    ]

    assert_cli_ok(
        run_cli(
            "baseline",
            "create",
            "--game-dir",
            str(mock_game.game_dir),
            "--out-dir",
            str(current_dir),
            "--state",
            "current",
            "--yes",
        )
    )
    assert_cli_ok(
        run_cli(
            "baseline",
            "create",
            "--game-dir",
            str(mock_game.game_dir),
            "--out-dir",
            str(pending_dir),
            "--state",
            "pending-verify",
            "--yes",
        )
    )

    promote = run_cli(
        "baseline",
        "promote",
        "--current-dir",
        str(current_dir),
        "--pending-dir",
        str(pending_dir),
        "--target-current-dir",
        str(current_dir),
        "--old-root",
        str(old_root),
        "--yes",
    )

    assert_cli_ok(promote)
    remaining = sorted(path.name for path in old_root.iterdir() if path.is_dir())
    assert len(remaining) == 5
    assert not removed_duplicate.exists()
    assert not removed_build.exists()
    assert not removed_older_build.exists()
    for old_dir in kept_builds:
        assert old_dir.exists()
    assert any("steam-b99000001" in name for name in remaining)


def test_baseline_apply_overwrites_without_creating_restore_backup(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"
    radio_info = mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml"

    create = run_cli(
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
    assert_cli_ok(create)
    original_md5 = md5_file(radio_info)
    radio_info.write_text("<RadioInfo />\n", encoding="utf-8")

    apply = run_cli(
        "baseline",
        "apply",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-dir",
        str(baseline_dir),
        "--yes",
    )

    assert_cli_ok(apply)
    assert md5_file(radio_info) == original_md5
    assert not any(full_project.backups_dir.rglob("baseline_apply_manifest.json"))
    assert "No backup or restore log was created." in apply.stdout


def test_baseline_apply_rejects_backup_dir_option(mock_game, full_project) -> None:
    baseline_dir = full_project.backups_dir / "baseline-current"

    result = run_cli(
        "baseline",
        "apply",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-dir",
        str(baseline_dir),
        "--backup-dir",
        str(full_project.backups_dir / "restore-log-should-fail"),
    )

    assert result.returncode != 0
    assert "unrecognized arguments: --backup-dir" in result.stderr


def test_inspect_bank_parses_mock_fsb5_names(mock_game) -> None:
    result = run_cli(
        "inspect-bank",
        "R4_Tracks_CU1",
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
    )

    assert_cli_ok(result)
    assert "Samples     : 3" in result.stdout
    assert "HZ6_R4_MOCK_SLOT_01" in result.stdout
    assert "HZ6_R4_MOCK_SLOT_02" in result.stdout
    assert "HZ6_R4_MOCK_SLOT_03" in result.stdout


def test_language_swap_apply_is_not_a_write_path() -> None:
    result = run_cli("language-swap", "apply")

    assert result.returncode != 0
    assert "invalid choice" in result.stderr


def test_legacy_snapshot_commands_are_removed() -> None:
    for command in ("create-snapshot", "restore-backup"):
        result = run_cli(command)
        assert result.returncode != 0
        assert "invalid choice" in result.stderr


def test_full_project_flow_builds_baseline_and_deploys_to_mock(mock_game, full_project) -> None:
    source = full_project.sources_dir / "FH Radio Studio Dev - Full Flow Test.wav"
    package_dir = full_project.packages_dir / "r4-full-flow"
    baseline_dir = full_project.backups_dir / "baseline-current"
    deploy_log_dir = full_project.backups_dir / "deploy-r4-full-flow"
    last_applied = full_project.metadata_dir / "last_applied_package_manifest.json"
    chs_table = mock_game.game_dir / "media" / "Stripped" / "StringTables" / "CHS.zip"
    target_table = mock_game.game_dir / "media" / "Stripped" / "StringTables" / "EN.zip"
    write_test_tone(source)
    mock_game.preferred_path.write_text("CHS", encoding="utf-8")

    build = run_cli(
        "build-package",
        str(source),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--out-dir",
        str(package_dir),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )
    assert_cli_ok(build)
    assert (package_dir / "package" / "fh_radio_studio_package_manifest.json").exists()
    assert (package_dir / "package" / "media" / "audio" / "RadioInfo_CN.xml").exists()
    assert (package_dir / "package" / "media" / "Stripped" / "StringTables" / "EN.zip").exists()

    baseline = run_cli(
        "baseline",
        "create",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(package_dir / "package"),
        "--out-dir",
        str(baseline_dir),
        "--state",
        "current",
        "--yes",
    )
    assert_cli_ok(baseline)
    baseline_manifest = baseline_dir / "baseline_manifest.json"
    baseline_payload = json.loads(baseline_manifest.read_text(encoding="utf-8"))
    assert baseline_payload["file_count"] == 3
    assert baseline_payload["game_version_id"] == "steam-b99000001"
    assert baseline_payload["backup_name"] == "fh6-steam-b99000001-baseline-current"

    deploy = run_cli(
        "deploy-package",
        str(package_dir / "package"),
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--last-applied-manifest",
        str(last_applied),
        "--preferred-path",
        str(mock_game.preferred_path),
        "--yes",
    )
    assert_cli_ok(deploy)
    deploy_manifest = deploy_log_dir / "deploy_manifest.json"
    assert not deploy_manifest.exists()
    last_applied_payload = json.loads(last_applied.read_text(encoding="utf-8"))
    assert last_applied_payload["game_version_id"] == "steam-b99000001"
    assert len(last_applied_payload["package_files"]) == 3
    assert md5_file(target_table) == md5_file(chs_table)
    assert mock_game.preferred_path.read_text(encoding="utf-8") == "EN"

    radio_info = mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml"
    root = ET.parse(radio_info).getroot()
    station = next(
        item
        for item in root.find("RadioStations").findall("RadioStation")
        if item.get("Number") == "4"
    )
    samples = station.find("SampleList").findall("Sample")
    free_roam_entries = station.find("PlayList").findall("Entry")
    assert {sample.get("DisplayName") for sample in samples} == {"Full Flow Test"}
    assert {sample.get("Artist") for sample in samples} == {"FH Radio Studio Dev"}
    assert [entry.get("Name") for entry in free_roam_entries] == ["HZ6_R4_MOCK_SLOT_01"]


def _build_unnamed_mock_fsb5_in_order(order: tuple[int, ...]) -> bytes:
    sample_headers = bytearray()
    for source_index in order:
        sample_count = MOCK_TRACKS[source_index][3]
        meta = (sample_count << 34) | (1 << 5) | (9 << 1)
        sample_headers.extend(struct.pack("<II", meta & 0xFFFFFFFF, (meta >> 32) & 0xFFFFFFFF))

    encoded_names = [b"\x00" for _ in order]
    offsets_size = 4 * len(encoded_names)
    offsets = []
    cursor = offsets_size
    for encoded in encoded_names:
        offsets.append(cursor)
        cursor += len(encoded)
    name_table = struct.pack(f"<{len(offsets)}I", *offsets) + b"".join(encoded_names)
    name_table += b"\x00" * ((-len(name_table)) % 16)

    header = bytearray(60)
    struct.pack_into(
        "<4s7I",
        header,
        0,
        b"FSB5",
        1,
        len(order),
        len(sample_headers),
        len(name_table),
        0,
        1,
        0,
    )
    return bytes(header) + bytes(sample_headers) + name_table


def test_build_package_matches_unnamed_bank_order_by_sample_length(mock_game, tmp_path) -> None:
    source_a = tmp_path / "sources" / "FH Radio Studio Dev - First.wav"
    source_b = tmp_path / "sources" / "FH Radio Studio Dev - Second.wav"
    source_c = tmp_path / "sources" / "FH Radio Studio Dev - Third.wav"
    package_dir = tmp_path / "packages" / "unnamed-bank-order"
    for source in (source_a, source_b, source_c):
        write_test_tone(source)

    bank_path = mock_game.game_dir / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank"
    bank_path.write_bytes(b"MOCKFH6BANK\x00" + _build_unnamed_mock_fsb5_in_order((2, 0, 1)))

    build = run_cli(
        "build-package",
        str(source_a),
        str(source_b),
        str(source_c),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--out-dir",
        str(package_dir),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )

    assert_cli_ok(build)
    assert "SampleLength-matched bank order" in build.stdout
    payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert payload["schema_version"] == 2
    assert len(payload["radios"]) == 1
    assert [item["target_sound_name"] for item in payload["radios"][0]["assignments"]] == [
        "HZ6_R4_MOCK_SLOT_03",
        "HZ6_R4_MOCK_SLOT_01",
        "HZ6_R4_MOCK_SLOT_02",
    ]

    radio_info = package_dir / "package" / "media" / "audio" / "RadioInfo_CN.xml"
    station = ET.parse(radio_info).getroot().find(".//RadioStation[@Number='4']")
    assert station is not None
    free_roam_entries = station.find("./PlayList[@Type='FreeRoam']").findall("Entry")
    assert [entry.get("Name") for entry in free_roam_entries] == [
        "HZ6_R4_MOCK_SLOT_03",
        "HZ6_R4_MOCK_SLOT_01",
        "HZ6_R4_MOCK_SLOT_02",
    ]


def test_baseline_bank_order_index_is_derived_and_used_for_build(mock_game, tmp_path) -> None:
    source_a = tmp_path / "sources" / "FH Radio Studio Dev - First.wav"
    source_b = tmp_path / "sources" / "FH Radio Studio Dev - Second.wav"
    source_c = tmp_path / "sources" / "FH Radio Studio Dev - Third.wav"
    baseline_dir = tmp_path / "backups" / "baseline-current"
    package_dir = tmp_path / "packages" / "baseline-bank-order"
    for source in (source_a, source_b, source_c):
        write_test_tone(source)

    bank_path = mock_game.game_dir / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank"
    bank_path.write_bytes(b"MOCKFH6BANK\x00" + _build_unnamed_mock_fsb5_in_order((2, 0, 1)))

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
    baseline_payload = json.loads(baseline_manifest.read_text(encoding="utf-8"))
    bank_order_entry = baseline_payload["derived_indexes"]["bank_order"]
    assert bank_order_entry["relative_path"] == "derived/bank_order.json"
    assert bank_order_entry["ok_bank_count"] == 1
    assert not any(
        str(item.get("install_relative_path", "")).startswith("derived/")
        for item in baseline_payload["files"]
    )

    bank_order_path = baseline_dir / "derived" / "bank_order.json"
    bank_order = json.loads(bank_order_path.read_text(encoding="utf-8"))
    r4_bank = next(
        item for item in bank_order["banks"] if item["bank_name"] == "R4_Tracks_CU1.assets.bank"
    )
    assert [slot["sound_name"] for slot in r4_bank["slots"]] == [
        "HZ6_R4_MOCK_SLOT_03",
        "HZ6_R4_MOCK_SLOT_01",
        "HZ6_R4_MOCK_SLOT_02",
    ]
    baseline_payload["files"].append(
        {
            "scope": "derived_index",
            "relative_path": "derived/bank_order.json",
            "install_relative_path": "derived/bank_order.json",
            "backup_path": str(bank_order_path),
            "size": bank_order_path.stat().st_size,
            "md5": md5_file(bank_order_path),
        }
    )
    baseline_manifest.write_text(
        json.dumps(baseline_payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    apply_plan = run_cli(
        "baseline",
        "apply",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-dir",
        str(baseline_dir),
    )
    assert_cli_ok(apply_plan)
    assert "derived/bank_order.json" not in apply_plan.stdout

    verify = run_cli(
        "verify-integrity",
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--json",
    )
    assert_cli_ok(verify)
    integrity = json.loads(verify.stdout)["integrity"]
    assert integrity["checked_files"] == 6
    assert integrity["unknown_files"] == 0

    bank_order_path.unlink()
    assert not bank_order_path.exists()

    build = run_cli(
        "build-package",
        str(source_a),
        str(source_b),
        str(source_c),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--out-dir",
        str(package_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )
    assert_cli_ok(build)
    assert "baseline bank-order calibration" in build.stdout
    assert "SampleLength-matched bank order" not in build.stdout
    assert bank_order_path.exists()
    regenerated_baseline = json.loads(baseline_manifest.read_text(encoding="utf-8"))
    assert (
        regenerated_baseline["derived_indexes"]["bank_order"]["relative_path"]
        == "derived/bank_order.json"
    )
    package_payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert [item["target_sound_name"] for item in package_payload["radios"][0]["assignments"]] == [
        "HZ6_R4_MOCK_SLOT_03",
        "HZ6_R4_MOCK_SLOT_01",
        "HZ6_R4_MOCK_SLOT_02",
    ]
    assert not (package_dir / "package" / "derived" / "bank_order.json").exists()


def test_build_package_can_stage_language_change_without_playlist(mock_game, tmp_path) -> None:
    package_dir = tmp_path / "packages" / "language-change-current-radio"
    baseline_dir = tmp_path / "backups" / "baseline-current"
    deploy_log_dir = tmp_path / "backups" / "deploy-language-change"
    last_applied = tmp_path / ".fh-radio-studio" / "last_applied_package_manifest.json"
    radio_info_cn = mock_game.game_dir / "media" / "audio" / "RadioInfo_CN.xml"
    radio_info_en = mock_game.game_dir / "media" / "audio" / "RadioInfo_EN.xml"
    target_bank = mock_game.game_dir / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank"
    chs_table = mock_game.game_dir / "media" / "Stripped" / "StringTables" / "CHS.zip"
    target_table = mock_game.game_dir / "media" / "Stripped" / "StringTables" / "EN.zip"
    original_radio_info_cn_md5 = md5_file(radio_info_cn)
    original_radio_info_en_md5 = md5_file(radio_info_en)
    original_bank_md5 = md5_file(target_bank)
    mock_game.preferred_path.write_text("CHS", encoding="utf-8")

    build = run_cli(
        "build-package",
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--out-dir",
        str(package_dir),
    )
    assert_cli_ok(build)

    manifest_path = package_dir / "package" / "fh_radio_studio_package_manifest.json"
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert payload["current_radio_passthrough"] is True
    assert payload["radio"] == 4
    assert payload["station"] == "Horizon XS"
    assert payload["target_bank_name"] == "R4_Tracks_CU1.assets.bank"
    assert len(payload["radios"]) == 1
    assert payload["radios"][0]["music"] == []
    assert payload["radios"][0]["assignments"] == []
    assert payload["language"]["source_lang"] == "CHS"
    assert payload["language"]["target_lang"] == "EN"
    package_radio_info_cn = package_dir / "package" / "media" / "audio" / "RadioInfo_CN.xml"
    package_radio_info_en = package_dir / "package" / "media" / "audio" / "RadioInfo_EN.xml"
    package_bank = (
        package_dir / "package" / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank"
    )
    assert md5_file(package_radio_info_cn) == original_radio_info_cn_md5
    assert md5_file(package_radio_info_en) == original_radio_info_en_md5
    assert md5_file(package_bank) == original_bank_md5
    assert (package_dir / "package" / "media" / "Stripped" / "StringTables" / "EN.zip").exists()
    assert [item["install_relative_path"] for item in payload["package_files"]] == [
        "media/audio/RadioInfo_CN.xml",
        "media/audio/RadioInfo_EN.xml",
        "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank",
        "media/Stripped/StringTables/EN.zip",
    ]

    baseline = run_cli(
        "baseline",
        "create",
        "--game-dir",
        str(mock_game.game_dir),
        "--package-dir",
        str(package_dir / "package"),
        "--out-dir",
        str(baseline_dir),
        "--state",
        "current",
        "--yes",
    )
    assert_cli_ok(baseline)
    baseline_manifest = baseline_dir / "baseline_manifest.json"
    baseline_payload = json.loads(baseline_manifest.read_text(encoding="utf-8"))
    assert baseline_payload["file_count"] == 4
    assert [item["install_relative_path"] for item in baseline_payload["files"]] == [
        "media/audio/RadioInfo_CN.xml",
        "media/audio/RadioInfo_EN.xml",
        "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank",
        "media/Stripped/StringTables/EN.zip",
    ]

    deploy = run_cli(
        "deploy-package",
        str(package_dir / "package"),
        "--game-dir",
        str(mock_game.game_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--last-applied-manifest",
        str(last_applied),
        "--preferred-path",
        str(mock_game.preferred_path),
        "--yes",
    )
    assert_cli_ok(deploy)
    assert not (deploy_log_dir / "deploy_manifest.json").exists()
    last_applied_payload = json.loads(last_applied.read_text(encoding="utf-8"))
    assert len(last_applied_payload["package_files"]) == 4
    assert md5_file(radio_info_cn) == original_radio_info_cn_md5
    assert md5_file(radio_info_en) == original_radio_info_en_md5
    assert md5_file(target_bank) == original_bank_md5
    assert md5_file(target_table) == md5_file(chs_table)
    assert mock_game.preferred_path.read_text(encoding="utf-8") == "EN"


def test_build_package_uses_playlist_plan_for_multiple_radios(mock_game, tmp_path) -> None:
    source_xs = tmp_path / "sources" / "FH Radio Studio Dev - XS Draft.wav"
    source_r5 = tmp_path / "sources" / "FH Radio Studio Dev - R5 Draft.wav"
    package_dir = tmp_path / "packages" / "multi-radio-plan"
    plan_path = tmp_path / ".fh-radio-studio" / "playlist_plan.json"
    write_test_tone(source_xs)
    write_test_tone(source_r5, duration_sec=1.0)

    bank_dir = mock_game.game_dir / "media" / "audio" / "FMODBanks"
    r5_bank = bank_dir / "R5_Tracks_Disk.assets.bank"
    r5_bank.write_bytes(b"MOCKFH6BANK\x00" + build_mock_fsb5(("HZ6_R5_MOCK_REFERENCE",)))

    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "assignments": [
                    {
                        "source": str(source_xs),
                        "radio_code": "XS",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                    {
                        "source": str(source_r5),
                        "radio_code": "R5",
                        "playlist_type": "Event",
                        "slot": 1,
                    },
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    build = run_cli(
        "build-package",
        str(source_xs),
        str(source_r5),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--playlist-plan",
        str(plan_path),
        "--out-dir",
        str(package_dir),
        "--playlist-mode",
        "only",
        "--progress-jsonl",
        "--skip-bank",
    )
    assert_cli_ok(build)
    progress_prefix = "FH_RADIO_STUDIO_PROGRESS "
    events = [
        json.loads(line[len(progress_prefix) :])
        for line in build.stderr.splitlines()
        if line.startswith(progress_prefix)
    ]
    plan_event = next(event for event in events if event.get("event") == "plan")
    labels = [step.get("label") for step in plan_event["steps"]]
    assert "Horizon XS 重建 FMOD bank" in labels
    assert "Radio Eterna 重建 FMOD bank" in labels
    assert "R4 重建 FMOD bank" not in labels
    assert "R5 重建 FMOD bank" not in labels

    manifest_path = package_dir / "package" / "fh_radio_studio_package_manifest.json"
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert payload["schema_version"] == 2
    assert payload["radio"] is None
    assert len(payload["radios"]) == 2
    by_radio = {item["radio"]: item for item in payload["radios"]}
    assert by_radio[4]["radio_code"] == "XS"
    assert by_radio[5]["radio_code"] == "R5"
    assert by_radio[4]["assignments"][0]["source"] == str(source_xs.resolve())
    assert by_radio[4]["assignments"][0]["playlist_types"] == ["FreeRoam"]
    assert by_radio[5]["assignments"][0]["source"] == str(source_r5.resolve())
    assert by_radio[5]["assignments"][0]["playlist_types"] == ["Event"]

    radio_info = package_dir / "package" / "media" / "audio" / "RadioInfo_CN.xml"
    root = ET.parse(radio_info).getroot()
    stations = root.find("RadioStations")
    assert stations is not None
    by_number = {station.get("Number"): station for station in stations.findall("RadioStation")}

    def playlist_names(station: ET.Element, playlist_type: str) -> list[str]:
        playlist = next(
            item for item in station.findall("PlayList") if item.get("Type") == playlist_type
        )
        return [entry.get("Name") for entry in playlist.findall("Entry")]

    assert playlist_names(by_number["4"], "FreeRoam") == ["HZ6_R4_MOCK_SLOT_01"]
    assert playlist_names(by_number["4"], "Event") == [
        "HZ6_R4_MOCK_SLOT_01",
        "HZ6_R4_MOCK_SLOT_02",
        "HZ6_R4_MOCK_SLOT_03",
    ]
    assert playlist_names(by_number["5"], "FreeRoam") == ["HZ6_R5_MOCK_REFERENCE"]
    assert playlist_names(by_number["5"], "Event") == ["HZ6_R5_MOCK_REFERENCE"]


def test_build_package_restores_builtin_targets_from_baseline(mock_game, tmp_path) -> None:
    baseline_dir = tmp_path / "backups" / "baseline-current"
    package_dir = tmp_path / "packages" / "restore-xs"
    plan_path = tmp_path / ".fh-radio-studio" / "playlist_plan.json"

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

    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "assignments": [
                    {
                        "source": str(tmp_path / "sources" / "old-custom-track.wav"),
                        "radio_code": "XS",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    }
                ],
                "builtin_targets": [
                    {"radio_code": "XS", "playlist_type": "FreeRoam"},
                    {"radio_code": "XS", "playlist_type": "Event"},
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    build = run_cli(
        "build-package",
        "--game-dir",
        str(mock_game.game_dir),
        "--source-audio-dir",
        str(baseline_dir / "media" / "audio"),
        "--source-string-tables-dir",
        str(baseline_dir / "media" / "Stripped" / "StringTables"),
        "--baseline-manifest",
        str(baseline_manifest),
        "--radio",
        "4",
        "--playlist-plan",
        str(plan_path),
        "--playlist-mode",
        "only",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--out-dir",
        str(package_dir),
    )
    assert_cli_ok(build)

    payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert payload["baseline_restore"] is True
    assert payload["radios"][0]["radio"] == 4
    assert payload["radios"][0]["assignments"] == []
    assert payload["restored_radios"][0]["playlist_types"] == ["FreeRoam", "Event"]
    assert md5_file(package_dir / "package" / "media" / "audio" / "RadioInfo_CN.xml") == md5_file(
        baseline_dir / "media" / "audio" / "RadioInfo_CN.xml"
    )
    assert md5_file(
        package_dir / "package" / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank"
    ) == md5_file(baseline_dir / "media" / "audio" / "FMODBanks" / "R4_Tracks_CU1.assets.bank")


def test_build_package_combines_custom_radios_and_builtin_restores(mock_game, tmp_path) -> None:
    source_xs = tmp_path / "sources" / "FH Radio Studio Dev - XS Draft.wav"
    package_dir = tmp_path / "packages" / "custom-plus-restore"
    baseline_dir = tmp_path / "backups" / "baseline-current"
    plan_path = tmp_path / ".fh-radio-studio" / "playlist_plan.json"
    write_test_tone(source_xs)

    bank_dir = mock_game.game_dir / "media" / "audio" / "FMODBanks"
    r5_bank = bank_dir / "R5_Tracks_Disk.assets.bank"
    r5_bank.write_bytes(b"MOCKFH6BANK\x00" + build_mock_fsb5(("HZ6_R5_MOCK_REFERENCE",)))

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

    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "assignments": [
                    {
                        "source": str(source_xs),
                        "radio_code": "XS",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                    {
                        "source": str(tmp_path / "sources" / "old-r5-custom.wav"),
                        "radio_code": "R5",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                ],
                "builtin_targets": [
                    {"radio_code": "R5", "playlist_type": "FreeRoam"},
                    {"radio_code": "R5", "playlist_type": "Event"},
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    build = run_cli(
        "build-package",
        str(source_xs),
        "--game-dir",
        str(mock_game.game_dir),
        "--source-audio-dir",
        str(baseline_dir / "media" / "audio"),
        "--source-string-tables-dir",
        str(baseline_dir / "media" / "Stripped" / "StringTables"),
        "--baseline-manifest",
        str(baseline_manifest),
        "--radio",
        "4",
        "--playlist-plan",
        str(plan_path),
        "--playlist-mode",
        "only",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--out-dir",
        str(package_dir),
        "--skip-bank",
    )
    assert_cli_ok(build)

    payload = json.loads(
        (package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert payload.get("baseline_restore") is not True
    assert [item["radio"] for item in payload["radios"]] == [4]
    assert payload["restored_radios"][0]["radio"] == 5
    assert payload["radios"][0]["assignments"][0]["source"] == str(source_xs.resolve())
    assert md5_file(
        package_dir / "package" / "media" / "audio" / "FMODBanks" / "R5_Tracks_Disk.assets.bank"
    ) == md5_file(baseline_dir / "media" / "audio" / "FMODBanks" / "R5_Tracks_Disk.assets.bank")


def test_build_package_enforces_baseline_playlist_entry_cap(mock_game, tmp_path) -> None:
    first = tmp_path / "sources" / "FH Radio Studio Dev - Hospital One.wav"
    second = tmp_path / "sources" / "FH Radio Studio Dev - Hospital Two.wav"
    package_dir = tmp_path / "packages" / "hospital-over-cap"
    write_test_tone(first)
    write_test_tone(second)

    bank_dir = mock_game.game_dir / "media" / "audio" / "FMODBanks"
    hospital_bank = bank_dir / "R6_Tracks_Disk.assets.bank"
    hospital_bank.write_bytes(
        b"MOCKFH6BANK\x00"
        + build_mock_fsb5(
            (
                "HZ6_R6_MOCK_REFERENCE",
                "HZ6_R6_MOCK_EXTRA_01",
                "HZ6_R6_MOCK_EXTRA_02",
            )
        )
    )

    build = run_cli(
        "build-package",
        str(first),
        str(second),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "6",
        "--playlist-mode",
        "only",
        "--out-dir",
        str(package_dir),
        "--skip-bank",
    )

    assert build.returncode != 0
    assert "baseline playlist has 1 entries" in (build.stdout + build.stderr)


def test_build_package_reuses_package_playlist_without_music_args(mock_game, tmp_path) -> None:
    source_xs = tmp_path / "sources" / "FH Radio Studio Dev - XS Current.wav"
    source_r5 = tmp_path / "sources" / "FH Radio Studio Dev - R5 Current.wav"
    current_package_dir = tmp_path / "packages" / "current"
    pending_package_dir = tmp_path / "packages" / "pending"
    plan_path = tmp_path / ".fh-radio-studio" / "playlist_plan.json"
    write_test_tone(source_xs)
    write_test_tone(source_r5, duration_sec=1.0)

    bank_dir = mock_game.game_dir / "media" / "audio" / "FMODBanks"
    r5_bank = bank_dir / "R5_Tracks_Disk.assets.bank"
    r5_bank.write_bytes(b"MOCKFH6BANK\x00" + build_mock_fsb5(("HZ6_R5_MOCK_REFERENCE",)))

    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "assignments": [
                    {
                        "source": str(source_xs),
                        "radio_code": "XS",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                    {
                        "source": str(source_r5),
                        "radio_code": "R5",
                        "playlist_type": "Event",
                        "slot": 1,
                    },
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    current = run_cli(
        "build-package",
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--playlist-plan",
        str(plan_path),
        "--out-dir",
        str(current_package_dir),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )
    assert_cli_ok(current)

    pending = run_cli(
        "build-package",
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--playlist-from-package",
        str(current_package_dir),
        "--out-dir",
        str(pending_package_dir),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )
    assert_cli_ok(pending)
    assert f"Playlist    : {current_package_dir}" in pending.stdout

    payload = json.loads(
        (pending_package_dir / "package" / "fh_radio_studio_package_manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert payload["playlist_plan"] is None
    by_radio = {item["radio"]: item for item in payload["radios"]}
    assert [item["source"] for item in by_radio[4]["music"]] == [str(source_xs.resolve())]
    assert [item["source"] for item in by_radio[5]["music"]] == [str(source_r5.resolve())]
    assert by_radio[4]["assignments"][0]["playlist_types"] == ["FreeRoam"]
    assert by_radio[5]["assignments"][0]["playlist_types"] == ["Event"]


def test_build_package_preflights_all_playlist_radios_before_writing(mock_game, tmp_path) -> None:
    source_xs = tmp_path / "sources" / "FH Radio Studio Dev - XS Draft.wav"
    source_r6 = tmp_path / "sources" / "FH Radio Studio Dev - R6 Draft.wav"
    package_dir = tmp_path / "packages" / "missing-radio-bank"
    plan_path = tmp_path / ".fh-radio-studio" / "playlist_plan.json"
    write_test_tone(source_xs)
    write_test_tone(source_r6)
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "assignments": [
                    {
                        "source": str(source_xs),
                        "radio_code": "XS",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                    {
                        "source": str(source_r6),
                        "radio_code": "R6",
                        "playlist_type": "FreeRoam",
                        "slot": 1,
                    },
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    build = run_cli(
        "build-package",
        str(source_xs),
        str(source_r6),
        "--game-dir",
        str(mock_game.game_dir),
        "--radio",
        "4",
        "--playlist-plan",
        str(plan_path),
        "--out-dir",
        str(package_dir),
        "--playlist-mode",
        "only",
        "--skip-bank",
    )

    assert build.returncode == 2
    assert "No R6_Tracks_*.assets.bank" in build.stderr
    assert not package_dir.exists()
