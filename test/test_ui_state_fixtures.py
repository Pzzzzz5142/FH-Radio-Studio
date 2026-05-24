from __future__ import annotations

import json

import pytest

from tools.test.create_ui_state_fixtures import CASES, generate_case


@pytest.mark.parametrize(
    ("case_id", "expected_level", "expected_reason"),
    [
        (
            "15-external-conflict-file-added",
            "external_conflict",
            "external_conflict_file_added",
        ),
        (
            "16-external-conflict-file-removed",
            "external_conflict",
            "external_conflict_file_removed",
        ),
        ("17-game-update-file-added", "game_changed", "game_update_file_added"),
        (
            "18-game-update-file-removed",
            "game_changed",
            "game_update_file_removed",
        ),
    ],
)
def test_ui_state_file_set_changes_route_to_pending_rebuild(
    tmp_path,
    case_id: str,
    expected_level: str,
    expected_reason: str,
) -> None:
    spec = next(item for item in CASES if item.case_id == case_id)
    case_dir = generate_case(tmp_path, spec, reset=False)

    payload = json.loads((case_dir / "expected-status.json").read_text(encoding="utf-8"))

    assert payload["actual_cli_level"] == expected_level
    assert payload["actual_cli_reason"] == expected_reason


def test_ui_state_old_package_written_is_trusted_during_pending_confirmation(
    tmp_path,
) -> None:
    case_id = "11-external-conflict-old-set-written"
    spec = next(item for item in CASES if item.case_id == case_id)
    case_dir = generate_case(tmp_path, spec, reset=False)

    payload = json.loads((case_dir / "expected-status.json").read_text(encoding="utf-8"))

    assert payload["expected_ui_state"] == "confirmation"
    assert payload["expected_reason"] == "old_package"
    assert payload["actual_cli_level"] == "previous_package_applied"
    assert payload["verify_integrity"]["payload"]["integrity"]["last_applied_package_matches"] == 1
