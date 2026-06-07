from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Optional

from .metadata import (
    build_track_metadata_cache_entry,
    collect_audio_files,
    metadata_cache_path,
)
from .project_json_guard import write_project_json
from .project_refs import (
    absolute_path,
    is_project_ref,
    normalize_project_ref,
    project_path_or_absolute,
    project_ref_for_path,
    resolve_project_ref,
    track_key_for_source_ref,
)


def cmd_migrate_project(args: argparse.Namespace) -> int:
    project_dir = absolute_path(Path(args.project_dir))
    changed = migrate_project_paths(project_dir)
    print(f"Project migrated: {project_dir}")
    print(f"JSON files updated: {changed}")
    return 0


def migrate_project_paths(project_dir: Path) -> int:
    project_dir = absolute_path(project_dir)
    track_refs: Dict[str, str] = {}
    changed = 0

    def track_key_for_project_path(path_value: object) -> Optional[str]:
        if isinstance(path_value, str) and is_project_ref(path_value):
            source_ref = normalize_project_ref(path_value)
            track_key = track_key_for_source_ref(source_ref)
            track_refs[track_key] = source_ref
            return track_key
        path = _path_from_value(path_value)
        if path is None:
            return None
        source_ref = project_ref_for_path(project_dir, path)
        if source_ref is None:
            return None
        track_key = track_key_for_source_ref(source_ref)
        track_refs[track_key] = source_ref
        return track_key

    # Seed the asset index from the actual current project audio folders first.
    for file in collect_audio_files([project_dir / "sources", project_dir / "siren"]):
        source_ref = project_ref_for_path(project_dir, file)
        if source_ref is not None:
            track_refs[track_key_for_source_ref(source_ref)] = source_ref

    metadata_changed = _migrate_metadata(project_dir, track_refs)
    changed += int(metadata_changed)

    changed += _migrate_track_key_file(
        project_dir,
        project_dir / "analysis" / "track_timing.json",
        track_key_for_project_path,
        source_field="source",
    )
    changed += _migrate_track_key_file(
        project_dir,
        project_dir / "analysis" / "build_timing_manifest.json",
        track_key_for_project_path,
        source_field="source",
    )
    changed += _migrate_track_key_file(
        project_dir,
        project_dir / "siren" / "siren_imports.json",
        track_key_for_project_path,
        source_field="path",
    )
    changed += _migrate_playlist_plan(
        project_dir,
        project_dir / ".fh-radio-studio" / "playlist_plan.json",
        track_key_for_project_path,
    )

    for manifest in (project_dir / "packages").glob(
        "*/package/fh_radio_studio_package_manifest.json"
    ):
        changed += _migrate_package_manifest(project_dir, manifest, track_key_for_project_path)
    for manifest in (project_dir / "backups").glob("*/baseline_manifest.json"):
        changed += _migrate_project_path_fields(
            project_dir,
            manifest,
            fields={"backup_path", "package_audio", "package_path"},
        )
    for manifest in (project_dir / "backups").glob("*/derived/bank_order.json"):
        changed += _migrate_project_path_fields(
            project_dir,
            manifest,
            fields={"source_baseline_manifest"},
        )
    last_applied_manifest = project_dir / ".fh-radio-studio" / "last_applied_package_manifest.json"
    changed += _migrate_package_manifest(
        project_dir,
        last_applied_manifest,
        track_key_for_project_path,
    )
    changed += _migrate_project_path_fields(
        project_dir,
        last_applied_manifest,
        fields={"source_package_manifest", "package_root"},
    )

    # Migration may have discovered refs from legacy JSON after metadata was
    # rewritten. Upsert missing asset entries so the new track_key records are
    # resolvable immediately.
    if _upsert_metadata_asset_entries(project_dir, track_refs):
        changed += 1 if not metadata_changed else 0

    if _mark_project_schema(project_dir):
        changed += 1
    return changed


def _migrate_metadata(project_dir: Path, track_refs: Dict[str, str]) -> bool:
    path = metadata_cache_path(project_dir)
    payload = _read_json(path)
    if not isinstance(payload, dict):
        _upsert_metadata_asset_entries(project_dir, track_refs)
        return path.exists()
    tracks = payload.get("tracks")
    if not isinstance(tracks, list):
        tracks = []
    changed = False
    out = []
    for item in tracks:
        if not isinstance(item, dict):
            out.append(item)
            continue
        entry = dict(item)
        source_ref = entry.get("source_ref")
        if isinstance(source_ref, str) and source_ref:
            canonical = normalize_project_ref(source_ref)
            track_key = track_key_for_source_ref(canonical)
            if entry.get("source_ref") != canonical:
                entry["source_ref"] = canonical
                changed = True
            if entry.get("track_key") != track_key:
                entry["track_key"] = track_key
                changed = True
            track_refs[track_key] = canonical
            if "source" in entry:
                entry.pop("source", None)
                changed = True
            if "path_key" in entry:
                entry.pop("path_key", None)
                changed = True
        else:
            source = _path_from_value(entry.get("source"))
            source_ref = project_ref_for_path(project_dir, source) if source is not None else None
            if source_ref is not None:
                track_key = track_key_for_source_ref(source_ref)
                entry["source_ref"] = source_ref
                entry["track_key"] = track_key
                entry.pop("source", None)
                entry.pop("path_key", None)
                track_refs[track_key] = source_ref
                changed = True
        if _encode_project_path_value(project_dir, entry, "cover_art_path"):
            changed = True
        loudness = entry.get("loudness_analysis")
        if isinstance(loudness, dict) and "source" in loudness:
            loudness = dict(loudness)
            loudness.pop("source", None)
            entry["loudness_analysis"] = loudness
            changed = True
        out.append(entry)
    if _upsert_metadata_asset_entries(project_dir, track_refs, existing=out):
        changed = True
        updated_payload = _read_json(path)
        if isinstance(updated_payload, dict) and isinstance(updated_payload.get("tracks"), list):
            out = updated_payload["tracks"]
    if changed:
        payload["schema_version"] = 2
        payload["updated_at"] = datetime.now(timezone.utc).isoformat()
        payload["tracks"] = out
        write_project_json(path, payload, project_dir=project_dir)
    return changed


def _upsert_metadata_asset_entries(
    project_dir: Path,
    track_refs: Dict[str, str],
    *,
    existing: Optional[list[Any]] = None,
) -> bool:
    path = metadata_cache_path(project_dir)
    payload = _read_json(path)
    if not isinstance(payload, dict):
        payload = {"schema_version": 2, "tracks": []}
    tracks = existing if existing is not None else payload.get("tracks")
    if not isinstance(tracks, list):
        tracks = []
    out_tracks: list[Any] = []
    by_key: Dict[str, Dict[str, Any]] = {}
    for item in tracks:
        if isinstance(item, dict):
            key = item.get("track_key")
            if isinstance(key, str) and key:
                if key in by_key:
                    continue
                by_key[key] = item
            out_tracks.append(item)
        else:
            out_tracks.append(item)
    changed = False
    for track_key, source_ref in sorted(track_refs.items()):
        if track_key in by_key:
            continue
        source = resolve_project_ref(project_dir, source_ref)
        try:
            entry = build_track_metadata_cache_entry(source, project_dir=project_dir)
        except OSError:
            entry = {"track_key": track_key, "source_ref": source_ref}
        by_key[track_key] = entry
        out_tracks.append(entry)
        changed = True
    if changed:
        payload["schema_version"] = 2
        payload["updated_at"] = datetime.now(timezone.utc).isoformat()
        payload["tracks"] = sorted(
            out_tracks,
            key=_metadata_sort_key,
        )
        write_project_json(path, payload, project_dir=project_dir)
    return changed


def _migrate_track_key_file(
    project_dir: Path,
    path: Path,
    track_key_for_project_path: Any,
    *,
    source_field: str,
) -> int:
    payload = _read_json(path)
    if not isinstance(payload, dict):
        return 0
    tracks = payload.get("tracks")
    if not isinstance(tracks, list):
        return 0
    changed = False
    out = []
    for item in tracks:
        if not isinstance(item, dict):
            out.append(item)
            continue
        entry = dict(item)
        track_key = entry.get("track_key")
        if not isinstance(track_key, str) or not track_key:
            track_key = track_key_for_project_path(entry.get(source_field))
            if track_key is not None:
                entry["track_key"] = track_key
                changed = True
        if isinstance(track_key, str) and track_key:
            if source_field in entry:
                entry.pop(source_field, None)
                changed = True
            if "path_key" in entry:
                entry.pop("path_key", None)
                changed = True
        out.append(entry)
    if changed:
        payload["schema_version"] = max(int(payload.get("schema_version") or 1), 2)
        payload["updated_at"] = datetime.now(timezone.utc).isoformat()
        payload["tracks"] = out
        write_project_json(path, payload, project_dir=project_dir)
    return int(changed)


# Legacy name-based radio codes (HOR/XS/…) that older app versions persisted in
# playlist plans. Codes are always `R{number}` now, so a one-time migration maps
# any survivors back to the canonical code. Real FH6 only ever produced
# HOR/BAS/BLK/XS; the rest are retained as historical demo aliases.
_LEGACY_RADIO_CODES: Dict[str, str] = {
    "HOR": "R1",
    "BAS": "R2",
    "BLK": "R3",
    "XS": "R4",
    "ROC": "R5",
    "TIM": "R6",
    "EUR": "R7",
    "MIX": "R8",
}


def _normalized_radio_code(raw: object) -> Optional[str]:
    if not isinstance(raw, str):
        return None
    code = raw.strip().upper()
    if not code:
        return None
    return _LEGACY_RADIO_CODES.get(code, code)


def _normalized_playlist_type(raw: object) -> Optional[str]:
    if raw is None:
        return None
    value = str(raw).strip()
    if not value:
        return None
    return "Event" if value.lower() == "event" else "FreeRoam"


def _migrate_radio_code_fields(value: Any) -> bool:
    changed = False
    if isinstance(value, list):
        for item in value:
            if _migrate_radio_code_fields(item):
                changed = True
        return changed
    if not isinstance(value, dict):
        return False

    raw = value.get("radio_code")
    if raw is None and "radioCode" in value:
        raw = value.get("radioCode")
    normalized = _normalized_radio_code(raw)
    if normalized is not None:
        if value.get("radio_code") != normalized:
            value["radio_code"] = normalized
            changed = True
        if "radioCode" in value:
            value.pop("radioCode", None)
            changed = True

    for item in value.values():
        if _migrate_radio_code_fields(item):
            changed = True
    return changed


def _migrate_playlist_type_fields(value: Any) -> bool:
    changed = False
    if isinstance(value, list):
        for item in value:
            if _migrate_playlist_type_fields(item):
                changed = True
        return changed
    if not isinstance(value, dict):
        return False

    raw = value.get("playlist_type")
    if raw is None and "playlistType" in value:
        raw = value.get("playlistType")
    normalized = _normalized_playlist_type(raw)
    if normalized is not None:
        if value.get("playlist_type") != normalized:
            value["playlist_type"] = normalized
            changed = True
        if "playlistType" in value:
            value.pop("playlistType", None)
            changed = True

    for item in value.values():
        if _migrate_playlist_type_fields(item):
            changed = True
    return changed


def _migrate_playlist_plan(project_dir: Path, path: Path, track_key_for_project_path: Any) -> int:
    payload = _read_json(path)
    if not isinstance(payload, dict):
        return 0
    changed = False

    assignments = payload.get("assignments")
    if isinstance(assignments, list):
        out = []
        for item in assignments:
            if not isinstance(item, dict):
                out.append(item)
                continue
            entry = dict(item)
            track_key = entry.get("track_key")
            if not isinstance(track_key, str) or not track_key:
                track_key = track_key_for_project_path(entry.get("source"))
                if track_key is not None:
                    entry["track_key"] = track_key
                    changed = True
            if isinstance(track_key, str) and track_key and "source" in entry:
                entry.pop("source", None)
                changed = True
            canonical = _normalized_radio_code(entry.get("radio_code") or entry.get("radioCode"))
            if canonical is not None:
                if entry.get("radio_code") != canonical:
                    entry["radio_code"] = canonical
                    changed = True
                if "radioCode" in entry:
                    entry.pop("radioCode", None)
                    changed = True
            playlist_type = _normalized_playlist_type(
                entry.get("playlist_type") or entry.get("playlistType")
            )
            if playlist_type is not None:
                if entry.get("playlist_type") != playlist_type:
                    entry["playlist_type"] = playlist_type
                    changed = True
                if "playlistType" in entry:
                    entry.pop("playlistType", None)
                    changed = True
            out.append(entry)
        payload["assignments"] = out

    builtin_targets = payload.get("builtin_targets")
    if isinstance(builtin_targets, list):
        targets_out = []
        for item in builtin_targets:
            if isinstance(item, dict):
                target = dict(item)
                canonical = _normalized_radio_code(
                    target.get("radio_code") or target.get("radioCode")
                )
                if canonical is not None:
                    if target.get("radio_code") != canonical:
                        target["radio_code"] = canonical
                        changed = True
                    if "radioCode" in target:
                        target.pop("radioCode", None)
                        changed = True
                playlist_type = _normalized_playlist_type(
                    target.get("playlist_type") or target.get("playlistType")
                )
                if playlist_type is not None:
                    if target.get("playlist_type") != playlist_type:
                        target["playlist_type"] = playlist_type
                        changed = True
                    if "playlistType" in target:
                        target.pop("playlistType", None)
                        changed = True
                targets_out.append(target)
            elif isinstance(item, str) and "|" in item:
                radio, _, rest = item.partition("|")
                canonical = _normalized_radio_code(radio)
                playlist_type = _normalized_playlist_type(rest)
                if canonical is not None:
                    targets_out.append(
                        {
                            "radio_code": canonical,
                            "playlist_type": playlist_type or "FreeRoam",
                        }
                    )
                    changed = True
                else:
                    targets_out.append(item)
            else:
                canonical = _normalized_radio_code(item)
                if canonical is not None:
                    targets_out.append({"radio_code": canonical, "playlist_type": "FreeRoam"})
                    changed = True
                else:
                    targets_out.append(item)
        payload["builtin_targets"] = targets_out

    if changed:
        payload["schema_version"] = max(int(payload.get("schema_version") or 1), 2)
        write_project_json(path, payload, project_dir=project_dir)
    return int(changed)


def _migrate_package_manifest(
    project_dir: Path, path: Path, track_key_for_project_path: Any
) -> int:
    payload = _read_json(path)
    if not isinstance(payload, dict):
        return 0
    changed = False
    for key in (
        "playlist_plan",
        "timing_manifest",
        "baseline_manifest",
        "source_audio_dir",
        "source_radio_info",
        "source_bank",
        "source_package_manifest",
        "package_root",
    ):
        if _encode_project_path_value(project_dir, payload, key):
            changed = True
    language = payload.get("language")
    if isinstance(language, dict) and _migrate_language_manifest(project_dir, language):
        changed = True
    if _migrate_radio_code_fields(payload):
        changed = True
    if _migrate_playlist_type_fields(payload):
        changed = True
    for unit in payload.get("radios") if isinstance(payload.get("radios"), list) else []:
        if not isinstance(unit, dict):
            continue
        for key in ("source_bank",):
            if _encode_project_path_value(project_dir, unit, key):
                changed = True
        source_by_index: Dict[int, str] = {}
        music = unit.get("music")
        if isinstance(music, list):
            for index, item in enumerate(music):
                if not isinstance(item, dict):
                    continue
                source = item.get("source")
                if isinstance(source, str) and source:
                    source_by_index[index] = source
                if _migrate_track_ref_entry(item, track_key_for_project_path, "source"):
                    changed = True
                if _encode_project_path_value(project_dir, item, "prepared_wav"):
                    changed = True
        assignments = unit.get("assignments")
        if isinstance(assignments, list):
            for item in assignments:
                if not isinstance(item, dict):
                    continue
                if not item.get("source") and item.get("source_index") in source_by_index:
                    item["source"] = source_by_index[int(item["source_index"])]
                if _migrate_track_ref_entry(item, track_key_for_project_path, "source"):
                    changed = True
                if _encode_project_path_value(project_dir, item, "staged_wav"):
                    changed = True
    package_files = payload.get("package_files")
    if isinstance(package_files, list):
        for item in package_files:
            if isinstance(item, dict) and _encode_project_path_value(project_dir, item, "path"):
                changed = True
    if _walk_project_fields(project_dir, payload, {"baseline_manifest"}):
        changed = True
    if changed:
        write_project_json(path, payload, project_dir=project_dir)
    return int(changed)


def _migrate_language_manifest(project_dir: Path, payload: Dict[str, Any]) -> bool:
    changed = False
    for key in (
        "source_string_tables_dir",
        "source_table",
        "target_table",
        "packaged_table",
    ):
        if _encode_project_path_value(project_dir, payload, key):
            changed = True
    return changed


def _migrate_track_ref_entry(
    entry: Dict[str, Any], track_key_for_project_path: Any, field: str
) -> bool:
    changed = False
    track_key = entry.get("track_key")
    if not isinstance(track_key, str) or not track_key:
        track_key = track_key_for_project_path(entry.get(field))
        if track_key is not None:
            entry["track_key"] = track_key
            changed = True
    if isinstance(track_key, str) and track_key and field in entry:
        entry.pop(field, None)
        changed = True
    if "path_key" in entry:
        entry.pop("path_key", None)
        changed = True
    return changed


def _migrate_project_path_fields(project_dir: Path, path: Path, *, fields: set[str]) -> int:
    payload = _read_json(path)
    if not isinstance(payload, dict):
        return 0
    changed = _walk_project_fields(project_dir, payload, fields)
    if changed:
        write_project_json(path, payload, project_dir=project_dir)
    return int(changed)


def _walk_project_fields(project_dir: Path, value: Any, fields: set[str]) -> bool:
    changed = False
    if isinstance(value, dict):
        for key, item in list(value.items()):
            if key in fields and _encode_project_path_value(project_dir, value, key):
                changed = True
            elif _walk_project_fields(project_dir, item, fields):
                changed = True
    elif isinstance(value, list):
        for item in value:
            if _walk_project_fields(project_dir, item, fields):
                changed = True
    return changed


def _encode_project_path_value(project_dir: Path, entry: Dict[str, Any], key: str) -> bool:
    value = entry.get(key)
    if not isinstance(value, str) or not value:
        return False
    if value.strip() == "-":
        return False
    if is_project_ref(value):
        normalized = normalize_project_ref(value)
        if normalized != value:
            entry[key] = normalized
            return True
        return False
    encoded = project_path_or_absolute(project_dir, Path(value))
    if encoded != value:
        entry[key] = encoded
        return True
    return False


def _metadata_sort_key(item: Any) -> str:
    if isinstance(item, dict):
        return str(item.get("source_ref") or item.get("source") or "").casefold()
    return ""


def _mark_project_schema(project_dir: Path) -> bool:
    path = project_dir / ".fh-radio-studio" / "project.json"
    payload = _read_json(path)
    if not isinstance(payload, dict):
        payload = {"schema": 2, "app": "FH Radio Studio"}
    changed = False
    if payload.get("schema") != 2:
        payload["schema"] = 2
        changed = True
    if payload.get("path_schema") != 2:
        payload["path_schema"] = 2
        changed = True
    current = str(absolute_path(project_dir))
    if payload.get("current_project_dir") != current:
        payload["current_project_dir"] = current
        changed = True
    if changed:
        write_project_json(path, payload, project_dir=project_dir)
    return changed


def _read_json(path: Path) -> Any:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _path_from_value(value: object) -> Optional[Path]:
    if not isinstance(value, str) or not value.strip():
        return None
    if value.strip() == "-":
        return None
    if is_project_ref(value):
        return None
    return Path(value).expanduser()
