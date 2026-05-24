from __future__ import annotations

import argparse
import contextlib
import io
import json
import math
import os
import shutil
import struct
import sys
import wave
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from backend.fh_radio_studio_cli.cli import main as fh_radio_studio_main
from tools.test.create_mock_game import (
    DEFAULT_BUILD_ID,
    GAME_ROOT_REL,
    PREFERRED_LANG_REL,
    build_radio_info,
    write_metadata,
    write_mock_bank,
    write_profile,
    write_radio_info_files,
    write_steam_manifest,
    write_string_tables,
)

DEFAULT_OUT = REPO_ROOT / "work" / "ui-state-fixtures"
NEXT_BUILD_ID = "99000002"
PACKAGE_REL = "media/audio/RadioInfo_CN.xml"


@dataclass
class CliResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass
class FixtureContext:
    case_id: str
    case_dir: Path
    mock_root: Path
    game_dir: Path
    preferred_path: Path
    project_dir: Path
    expected_ui_state: str
    expected_reason: Optional[str] = None
    expected_primary_action: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def backups_dir(self) -> Path:
        return self.project_dir / "backups"

    @property
    def packages_dir(self) -> Path:
        return self.project_dir / "packages"

    @property
    def metadata_dir(self) -> Path:
        return self.project_dir / ".fh-radio-studio"

    @property
    def current_baseline_dir(self) -> Path:
        return self.backups_dir / "baseline-current"

    @property
    def pending_baseline_dir(self) -> Path:
        return self.backups_dir / "baseline-pending-verify"

    @property
    def current_package_dir(self) -> Path:
        return self.packages_dir / "current"

    @property
    def pending_package_dir(self) -> Path:
        return self.packages_dir / "pending"

    @property
    def last_applied_manifest(self) -> Path:
        return self.metadata_dir / "last_applied_package_manifest.json"


@dataclass(frozen=True)
class CaseSpec:
    case_id: str
    expected_ui_state: str
    setup: Callable[[FixtureContext], None]
    expected_reason: Optional[str] = None
    expected_primary_action: str = ""


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def write_json(path: Path, data: object) -> None:
    write_text(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def md5_file(path: Path) -> str:
    import hashlib

    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_cli(args: list[str]) -> CliResult:
    stdout = io.StringIO()
    stderr = io.StringIO()
    old_cwd = Path.cwd()
    try:
        os.chdir(REPO_ROOT)
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                code = fh_radio_studio_main(args)
            except SystemExit as exc:
                code = int(exc.code) if isinstance(exc.code, int) else 1
    finally:
        os.chdir(old_cwd)
    return CliResult(
        args=args,
        returncode=int(code or 0),
        stdout=stdout.getvalue(),
        stderr=stderr.getvalue(),
    )


def require_cli(args: list[str]) -> CliResult:
    result = run_cli(args)
    if not result.ok:
        raise RuntimeError(
            "CLI failed: "
            + " ".join(args)
            + f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def create_mock_game(root: Path, build_id: str) -> tuple[Path, Path]:
    game_dir = root / GAME_ROOT_REL
    write_steam_manifest(root, build_id)
    write_radio_info_files(game_dir)
    write_mock_bank(game_dir)
    write_string_tables(game_dir)
    write_profile(root)
    write_metadata(root, game_dir, build_id)
    return root, game_dir


def write_project_manifest(ctx: FixtureContext) -> None:
    for directory in (
        ctx.project_dir,
        ctx.project_dir / "sources",
        ctx.packages_dir,
        ctx.backups_dir,
        ctx.project_dir / "analysis",
        ctx.metadata_dir,
    ):
        directory.mkdir(parents=True, exist_ok=True)
    write_json(
        ctx.metadata_dir / "project.json",
        {
            "schema": 1,
            "app": "FH Radio Studio",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "folders": {
                "sources": "sources",
                "packages": "packages",
                "backups": "backups",
                "analysis": "analysis",
            },
            "settings": {
                "game_dir": str(ctx.game_dir),
                "preferred_path": str(ctx.preferred_path),
                "radio": 4,
                "source_lang": "CHS",
                "target_lang": "EN",
                "ai_profile": "local-base",
            },
        },
    )


def write_test_tone(path: Path, duration_sec: float = 2.0, sample_rate: int = 48000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(duration_sec * sample_rate)
    amplitude = int(32767 * 0.20)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        for index in range(frames):
            value = int(amplitude * math.sin(2 * math.pi * 440.0 * index / sample_rate))
            wav.writeframesraw(struct.pack("<hh", value, value))


def install_path(game_dir: Path, install_rel: str = PACKAGE_REL) -> Path:
    return game_dir / Path(*install_rel.split("/"))


def write_radioinfo_variant(path: Path, label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tree = build_radio_info("CN")
    tree.getroot().set("FixtureState", label)
    tree.write(
        path,
        encoding="utf-8",
        xml_declaration=True,
        short_empty_elements=True,
    )


def change_build(ctx: FixtureContext, build_id: str = NEXT_BUILD_ID) -> None:
    write_steam_manifest(ctx.mock_root, build_id)


def create_baseline(ctx: FixtureContext, *, state: str = "current") -> Path:
    out_dir = ctx.current_baseline_dir if state == "current" else ctx.pending_baseline_dir
    require_cli(
        [
            "baseline",
            "create",
            "--game-dir",
            str(ctx.game_dir),
            "--out-dir",
            str(out_dir),
            "--state",
            state if state != "pending" else "pending-verify",
            "--overwrite",
            "--yes",
        ]
    )
    return out_dir / "baseline_manifest.json"


def create_package(
    ctx: FixtureContext,
    *,
    slot: str = "current",
    label: str,
    version_id: str = f"steam-b{DEFAULT_BUILD_ID}",
) -> Path:
    package_slot = ctx.current_package_dir if slot == "current" else ctx.pending_package_dir
    package_root = package_slot / "package"
    package_file = package_root / Path(*PACKAGE_REL.split("/"))
    source = ctx.project_dir / "sources" / f"{slot}-{label}.wav"
    write_test_tone(source)
    write_radioinfo_variant(package_file, label)
    package_item = {
        "kind": "radio_info",
        "relative_path": "RadioInfo_CN.xml",
        "install_relative_path": PACKAGE_REL,
        "path": str(package_file),
        "size": package_file.stat().st_size,
        "md5": md5_file(package_file),
    }
    radio_package = {
        "radio": 4,
        "radio_code": "XS",
        "station": "Horizon XS",
        "target_bank_name": "R4_Tracks_CU1.assets.bank",
        "bank_slots": 3,
        "music": [
            {
                "source": str(source),
                "display_name": label,
                "artist": "FH Radio Studio Fixture",
            }
        ],
        "assignments": [
            {
                "slot_index": 0,
                "source_index": 0,
                "source": str(source),
                "playlist_entry": True,
                "playlist_types": ["FreeRoam", "Event"],
                "display_name": label,
                "artist": "FH Radio Studio Fixture",
            }
        ],
    }
    manifest = {
        "schema_version": 2,
        "kind": "fh_radio_studio_package_fixture",
        "package_name": f"{slot}-{label}",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "game_dir": str(ctx.game_dir),
        "game_version_id": version_id,
        "supported_game_version_ids": [version_id],
        "radio": 4,
        "station": "Horizon XS",
        "target_bank_name": "R4_Tracks_CU1.assets.bank",
        "bank_slots": 3,
        "playlist_mode": "only",
        "skip_bank": True,
        "runtime_verified": False,
        "radios": [radio_package],
        "package_files": [package_item],
    }
    write_json(package_root / "fh_radio_studio_package_manifest.json", manifest)
    write_text(package_root / "INSTALL_README.txt", "UI state fixture package.\n")
    return package_slot


def read_package_manifest(package_dir: Path) -> dict[str, object]:
    manifest_path = package_dir / "package" / "fh_radio_studio_package_manifest.json"
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def apply_package_to_game(ctx: FixtureContext, package_dir: Path) -> None:
    manifest = read_package_manifest(package_dir)
    package_root = package_dir / "package"
    for item in manifest.get("package_files", []):
        if not isinstance(item, dict):
            continue
        rel = str(item["install_relative_path"]).replace("\\", "/")
        src = package_root / Path(*rel.split("/"))
        dest = install_path(ctx.game_dir, rel)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)


def write_last_applied_from_package(ctx: FixtureContext, package_dir: Path) -> None:
    manifest = read_package_manifest(package_dir)
    files = []
    for item in manifest.get("package_files", []):
        if not isinstance(item, dict):
            continue
        files.append(
            {
                "kind": item.get("kind", "file"),
                "relative_path": item.get("relative_path"),
                "install_relative_path": item.get("install_relative_path"),
                "size": item.get("size"),
                "md5": item.get("md5"),
            }
        )
    write_json(
        ctx.last_applied_manifest,
        {
            "schema_version": 1,
            "kind": "last_applied_package",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "source_package_manifest": str(
                package_dir / "package" / "fh_radio_studio_package_manifest.json"
            ),
            "package_root": str(package_dir / "package"),
            "game_version_id": manifest.get("game_version_id"),
            "supported_game_version_ids": manifest.get("supported_game_version_ids", []),
            "package_name": manifest.get("package_name"),
            "package_files": files,
        },
    )


def write_last_applied_from_game(ctx: FixtureContext, *, label: str) -> None:
    game_file = install_path(ctx.game_dir)
    write_json(
        ctx.last_applied_manifest,
        {
            "schema_version": 1,
            "kind": "last_applied_package",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "package_name": label,
            "game_version_id": f"steam-b{DEFAULT_BUILD_ID}",
            "supported_game_version_ids": [f"steam-b{DEFAULT_BUILD_ID}"],
            "package_files": [
                {
                    "kind": "radio_info",
                    "relative_path": "RadioInfo_CN.xml",
                    "install_relative_path": PACKAGE_REL,
                    "size": game_file.stat().st_size,
                    "md5": md5_file(game_file),
                }
            ],
        },
    )


def add_game_file(ctx: FixtureContext) -> None:
    source = ctx.game_dir / "media" / "audio" / "RadioInfo_EN.xml"
    target = ctx.game_dir / "media" / "audio" / "RadioInfo_JP.xml"
    shutil.copy2(source, target)
    ctx.notes.append("Added protected game file: media/audio/RadioInfo_JP.xml")


def remove_game_file(ctx: FixtureContext) -> None:
    target = ctx.game_dir / "media" / "audio" / "RadioInfo_EN.xml"
    target.unlink()
    ctx.notes.append("Removed protected game file: media/audio/RadioInfo_EN.xml")


def corrupt_current_baseline(ctx: FixtureContext) -> None:
    manifest = json.loads(
        (ctx.current_baseline_dir / "baseline_manifest.json").read_text(encoding="utf-8")
    )
    first = manifest["files"][0]
    backup_path = Path(first["backup_path"])
    write_text(backup_path, "corrupted baseline fixture\n")
    ctx.notes.append(f"Corrupted baseline file: {backup_path}")


def setup_no_baseline(ctx: FixtureContext) -> None:
    ctx.notes.append("No baseline or package artifacts are present.")


def setup_baseline_no_package(ctx: FixtureContext) -> None:
    create_baseline(ctx)


def setup_baseline_package_ready(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="current-ready")


def setup_package_applied(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    package = create_package(ctx, label="current-applied")
    apply_package_to_game(ctx, package)
    write_last_applied_from_package(ctx, package)


def setup_previous_package_applied(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    write_radioinfo_variant(install_path(ctx.game_dir), "previous-applied-v1")
    write_last_applied_from_game(ctx, label="previous-applied-v1")
    create_package(ctx, label="current-ready-v2")


def setup_safe_build_bump(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="current-ready")
    change_build(ctx)


def setup_game_update_pending_rebuild(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="old-current")
    change_build(ctx)
    write_radioinfo_variant(install_path(ctx.game_dir), "steam-update-current-file")


def setup_game_update_confirm_pending_baseline(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="old-current")
    change_build(ctx)
    write_radioinfo_variant(install_path(ctx.game_dir), "steam-update-pending-baseline")
    create_baseline(ctx, state="pending-verify")
    create_package(ctx, slot="pending", label="pending-ready", version_id=f"steam-b{NEXT_BUILD_ID}")


def setup_game_update_confirm_pending_package(ctx: FixtureContext) -> None:
    setup_game_update_confirm_pending_baseline(ctx)
    apply_package_to_game(ctx, ctx.pending_package_dir)


def setup_external_conflict_pending_rebuild(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="old-current")
    write_radioinfo_variant(install_path(ctx.game_dir), "same-build-untrusted-conflict")


def setup_external_conflict_old_set_written(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    old_package = create_package(ctx, label="old-current")
    write_radioinfo_variant(install_path(ctx.game_dir), "same-build-untrusted-conflict")
    create_baseline(ctx, state="pending-verify")
    create_package(ctx, slot="pending", label="pending-from-conflict")
    apply_package_to_game(ctx, old_package)


def setup_external_conflict_new_set_written(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="old-current")
    write_radioinfo_variant(install_path(ctx.game_dir), "same-build-untrusted-conflict")
    create_baseline(ctx, state="pending-verify")
    pending = create_package(ctx, slot="pending", label="pending-from-conflict")
    apply_package_to_game(ctx, pending)


def setup_corrupt_baseline(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="current-ready")
    corrupt_current_baseline(ctx)


def setup_language_setting_ignored(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    create_package(ctx, label="current-ready")
    write_text(ctx.preferred_path, "JP\n")
    ctx.notes.append(
        "Changed UserPreferredLang to JP; integrity should not change because it is handled by the language packaging flow."
    )


def setup_external_file_added(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    add_game_file(ctx)


def setup_external_file_removed(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    remove_game_file(ctx)


def setup_game_update_file_added(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    change_build(ctx)
    add_game_file(ctx)


def setup_game_update_file_removed(ctx: FixtureContext) -> None:
    create_baseline(ctx)
    change_build(ctx)
    remove_game_file(ctx)


CASES: list[CaseSpec] = [
    CaseSpec(
        "01-no-baseline",
        "no_baseline",
        setup_no_baseline,
        expected_primary_action="create baseline",
    ),
    CaseSpec(
        "02-baseline-no-package",
        "no_package",
        setup_baseline_no_package,
        expected_primary_action="build package",
    ),
    CaseSpec(
        "03-baseline-current-package-ready",
        "baseline",
        setup_baseline_package_ready,
        expected_primary_action="deploy current package",
    ),
    CaseSpec(
        "04-package-applied",
        "package_applied",
        setup_package_applied,
        expected_primary_action="no required action",
    ),
    CaseSpec(
        "05-previous-package-applied",
        "previous_package_applied",
        setup_previous_package_applied,
        expected_primary_action="deploy current package",
    ),
    CaseSpec(
        "06-safe-build-bump",
        "safe_build_bump",
        setup_safe_build_bump,
        expected_primary_action="safe bump",
    ),
    CaseSpec(
        "07-game-update-pending-rebuild",
        "pending_rebuild",
        setup_game_update_pending_rebuild,
        expected_reason="game_update",
        expected_primary_action="create pending set",
    ),
    CaseSpec(
        "08-game-update-confirm-pending-baseline",
        "confirmation",
        setup_game_update_confirm_pending_baseline,
        expected_reason="pending_baseline",
        expected_primary_action="confirm and consume pending baseline",
    ),
    CaseSpec(
        "09-game-update-confirm-pending-package",
        "confirmation",
        setup_game_update_confirm_pending_package,
        expected_reason="pending_package",
        expected_primary_action="confirm and consume pending package",
    ),
    CaseSpec(
        "10-external-conflict-pending-rebuild",
        "pending_rebuild",
        setup_external_conflict_pending_rebuild,
        expected_reason="external_conflict",
        expected_primary_action="create pending set or write old set",
    ),
    CaseSpec(
        "11-external-conflict-old-set-written",
        "confirmation",
        setup_external_conflict_old_set_written,
        expected_reason="old_package",
        expected_primary_action="confirm old set and discard pending",
    ),
    CaseSpec(
        "12-external-conflict-new-set-written",
        "confirmation",
        setup_external_conflict_new_set_written,
        expected_reason="pending_package",
        expected_primary_action="confirm and consume pending package",
    ),
    CaseSpec(
        "13-corrupt-baseline-reset-only",
        "reset_only",
        setup_corrupt_baseline,
        expected_primary_action="reset baseline from game",
    ),
    CaseSpec(
        "14-language-setting-ignored",
        "baseline",
        setup_language_setting_ignored,
        expected_primary_action="ignore UserPreferredLang drift",
    ),
    CaseSpec(
        "15-external-conflict-file-added",
        "pending_rebuild",
        setup_external_file_added,
        expected_reason="external_conflict_file_added",
        expected_primary_action="create pending set or reset baseline",
    ),
    CaseSpec(
        "16-external-conflict-file-removed",
        "pending_rebuild",
        setup_external_file_removed,
        expected_reason="external_conflict_file_removed",
        expected_primary_action="create pending set or reset baseline",
    ),
    CaseSpec(
        "17-game-update-file-added",
        "pending_rebuild",
        setup_game_update_file_added,
        expected_reason="game_update_file_added",
        expected_primary_action="create pending set",
    ),
    CaseSpec(
        "18-game-update-file-removed",
        "pending_rebuild",
        setup_game_update_file_removed,
        expected_reason="game_update_file_removed",
        expected_primary_action="create pending set",
    ),
]


def selected_package_dir(ctx: FixtureContext) -> Optional[Path]:
    pending_manifest = ctx.pending_baseline_dir / "baseline_manifest.json"
    pending_package = ctx.pending_package_dir / "package" / "fh_radio_studio_package_manifest.json"
    current_package = ctx.current_package_dir / "package" / "fh_radio_studio_package_manifest.json"
    if pending_manifest.exists() and pending_package.exists():
        return ctx.pending_package_dir
    if current_package.exists():
        return ctx.current_package_dir
    return None


def verify_fixture(ctx: FixtureContext) -> dict[str, object]:
    args = ["verify-integrity", "--game-dir", str(ctx.game_dir)]
    package_dir = selected_package_dir(ctx)
    current_manifest = ctx.current_baseline_dir / "baseline_manifest.json"
    pending_manifest = ctx.pending_baseline_dir / "baseline_manifest.json"
    current_package_manifest = (
        ctx.current_package_dir / "package" / "fh_radio_studio_package_manifest.json"
    )
    if package_dir is not None:
        args.extend(["--package-dir", str(package_dir)])
    if current_manifest.exists():
        args.extend(["--baseline-manifest", str(current_manifest)])
    if pending_manifest.exists():
        args.extend(["--pending-baseline-manifest", str(pending_manifest)])
    if pending_manifest.exists() and current_package_manifest.exists():
        args.extend(["--last-applied-package-manifest", str(current_package_manifest)])
    elif ctx.last_applied_manifest.exists():
        args.extend(["--last-applied-package-manifest", str(ctx.last_applied_manifest)])
    args.append("--json")
    result = run_cli(args)
    payload: object
    try:
        payload = json.loads(result.stdout) if result.stdout.strip() else None
    except json.JSONDecodeError:
        payload = None
    return {
        "args": result.args,
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "payload": payload,
    }


def status_fixture(ctx: FixtureContext) -> dict[str, object]:
    args = [
        "status",
        "--game-dir",
        str(ctx.game_dir),
        "--radio",
        "4",
        "--source",
        "CHS",
        "--target",
        "EN",
        "--preferred-path",
        str(ctx.preferred_path),
    ]
    current_manifest = ctx.current_baseline_dir / "baseline_manifest.json"
    if current_manifest.exists():
        args.extend(["--baseline-manifest", str(current_manifest)])
    args.append("--json")
    result = run_cli(args)
    payload: object
    try:
        payload = json.loads(result.stdout) if result.stdout.strip() else None
    except json.JSONDecodeError:
        payload = None
    return {
        "args": result.args,
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "payload": payload,
    }


def write_fixture_readme(ctx: FixtureContext, status: dict[str, object]) -> None:
    payload = status.get("payload") if isinstance(status.get("payload"), dict) else {}
    integrity = payload.get("integrity") if isinstance(payload.get("integrity"), dict) else {}
    actual_level = integrity.get("level") or "(verify failed)"
    notes = "\n".join(f"- {note}" for note in ctx.notes) or "- None"
    write_text(
        ctx.case_dir / "README.md",
        f"""# {ctx.case_id}

Open this fixture project in the FH Radio Studio app to inspect one UI state.

Project dir:

```text
{ctx.project_dir}
```

Game dir:

```text
{ctx.game_dir}
```

Expected future UI state: `{ctx.expected_ui_state}`
Expected reason: `{ctx.expected_reason or ""}`
Expected primary action: `{ctx.expected_primary_action}`

Current CLI integrity level: `{actual_level}`

Notes:

{notes}

Regenerate this case after destructive UI testing:

```powershell
uv run python tools/test/create_ui_state_fixtures.py --case {ctx.case_id} --reset
```
""",
    )


def make_context(case_dir: Path, spec: CaseSpec) -> FixtureContext:
    mock_root = case_dir / "mock-game" / f"fh6-steam-b{DEFAULT_BUILD_ID}"
    _, game_dir = create_mock_game(mock_root, DEFAULT_BUILD_ID)
    project_dir = case_dir / "project"
    ctx = FixtureContext(
        case_id=spec.case_id,
        case_dir=case_dir,
        mock_root=mock_root,
        game_dir=game_dir,
        preferred_path=mock_root / PREFERRED_LANG_REL,
        project_dir=project_dir,
        expected_ui_state=spec.expected_ui_state,
        expected_reason=spec.expected_reason,
        expected_primary_action=spec.expected_primary_action,
    )
    write_project_manifest(ctx)
    return ctx


def generate_case(out_dir: Path, spec: CaseSpec, *, reset: bool) -> Path:
    case_dir = out_dir / spec.case_id
    if case_dir.exists():
        if not reset:
            raise RuntimeError(f"Fixture already exists; pass --reset to recreate: {case_dir}")
        shutil.rmtree(case_dir)
    case_dir.mkdir(parents=True, exist_ok=True)
    ctx = make_context(case_dir, spec)
    spec.setup(ctx)
    status = verify_fixture(ctx)
    dashboard_status = status_fixture(ctx)
    if dashboard_status["returncode"] != 0:
        raise RuntimeError(
            "Generated fixture cannot refresh dashboard status: "
            + spec.case_id
            + "\nstdout:\n"
            + str(dashboard_status["stdout"])
            + "\nstderr:\n"
            + str(dashboard_status["stderr"])
        )
    payload = status.get("payload") if isinstance(status.get("payload"), dict) else {}
    integrity = payload.get("integrity") if isinstance(payload.get("integrity"), dict) else {}
    write_json(
        case_dir / "expected-status.json",
        {
            "schema_version": 1,
            "case_id": spec.case_id,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "project_dir": str(ctx.project_dir),
            "game_dir": str(ctx.game_dir),
            "preferred_path": str(ctx.preferred_path),
            "expected_ui_state": ctx.expected_ui_state,
            "expected_reason": ctx.expected_reason,
            "expected_primary_action": ctx.expected_primary_action,
            "actual_cli_level": integrity.get("level"),
            "actual_cli_reason": integrity.get("reason"),
            "actual_cli_checked_files": integrity.get("checked_files"),
            "actual_cli_changed_files": integrity.get("changed_files"),
            "actual_cli_unknown_files": integrity.get("unknown_files"),
            "actual_cli_baseline_matches": integrity.get("baseline_matches"),
            "actual_cli_pending_baseline_matches": integrity.get("pending_baseline_matches"),
            "actual_cli_package_matches": integrity.get("package_matches"),
            "notes": ctx.notes,
            "status": dashboard_status,
            "verify_integrity": status,
        },
    )
    write_fixture_readme(ctx, status)
    return case_dir


def assert_safe_output_dir(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if resolved == REPO_ROOT:
        raise SystemExit("Refusing to use the repo root as fixture output.")
    if resolved.parent == resolved:
        raise SystemExit("Refusing to use a filesystem root as fixture output.")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate disposable UI state fixture projects for FH Radio Studio."
    )
    parser.add_argument(
        "--out", default=str(DEFAULT_OUT), help="Output directory for fixture cases."
    )
    parser.add_argument(
        "--case",
        action="append",
        dest="cases",
        help="Generate only this case id. Can be passed more than once.",
    )
    parser.add_argument(
        "--reset", action="store_true", help="Delete and recreate selected fixture cases."
    )
    parser.add_argument("--list", action="store_true", help="List available case ids.")
    args = parser.parse_args()

    if args.list:
        for spec in CASES:
            reason = f" ({spec.expected_reason})" if spec.expected_reason else ""
            print(f"{spec.case_id}: {spec.expected_ui_state}{reason}")
        return 0

    out_dir = assert_safe_output_dir(Path(args.out))
    by_id = {spec.case_id: spec for spec in CASES}
    selected = CASES
    if args.cases:
        missing = [case_id for case_id in args.cases if case_id not in by_id]
        if missing:
            raise SystemExit(f"Unknown case id(s): {', '.join(missing)}")
        selected = [by_id[case_id] for case_id in args.cases]

    if out_dir.exists() and args.reset and not args.cases:
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    generated = []
    for spec in selected:
        generated.append(generate_case(out_dir, spec, reset=args.reset))

    write_json(
        out_dir / "index.json",
        {
            "schema_version": 1,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "cases": [
                {
                    "case_id": spec.case_id,
                    "path": str(out_dir / spec.case_id),
                    "project_dir": str(out_dir / spec.case_id / "project"),
                    "expected_ui_state": spec.expected_ui_state,
                    "expected_reason": spec.expected_reason,
                    "expected_primary_action": spec.expected_primary_action,
                }
                for spec in selected
            ],
        },
    )
    print(f"Generated {len(generated)} fixture case(s) under {out_dir}")
    for path in generated:
        print(f"  {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
