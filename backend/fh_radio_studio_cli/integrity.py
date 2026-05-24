from __future__ import annotations

from .baseline import (
    baseline_plan,
    baseline_supported_version_ids,
    baseline_supports_game_version,
    baseline_version_id,
)
from .baseline_order import is_baseline_derived_index_path
from .common import *
from .game import resolve_game_dir


def _norm_path(value: object) -> str:
    return str(value or "").replace("\\", "/").strip("/")


def _resolve_existing_path(value: Optional[str]) -> Optional[Path]:
    if not value:
        return None
    path = Path(value).expanduser()
    return path if path.exists() else None


def _package_manifest_path(package_dir: Optional[str]) -> Optional[Path]:
    if not package_dir:
        return None
    root = package_root_dir(Path(package_dir).expanduser())
    candidate = root / "fh_radio_studio_package_manifest.json"
    if candidate.exists():
        return candidate
    return None


def _manifest_md5s_by_path(manifest_path: Optional[Path]) -> Dict[str, str]:
    if not manifest_path or not manifest_path.exists():
        return {}
    manifest = load_manifest(manifest_path)
    result: Dict[str, str] = {}
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict):
            continue
        md5 = item.get("md5")
        if not isinstance(md5, str) or not md5:
            continue
        install_rel = _baseline_install_relative_path(item)
        rel = _norm_path(item.get("relative_path"))
        if is_baseline_derived_index_path(install_rel) or is_baseline_derived_index_path(rel):
            continue
        if install_rel:
            result[install_rel] = md5
        if rel:
            result[rel] = md5
    return result


def _load_manifest_if_exists(manifest_path: Optional[Path]) -> Dict[str, object]:
    if not manifest_path or not manifest_path.exists():
        return {}
    return load_manifest(manifest_path)


def _last_applied_md5s_by_path(manifest_path: Optional[Path]) -> Dict[str, str]:
    if not manifest_path or not manifest_path.exists():
        return {}
    manifest = load_manifest(manifest_path)
    files = manifest.get("package_files")
    if isinstance(files, list):
        return _package_md5s_from_items(files)
    deploy_files = manifest.get("files")
    result: Dict[str, str] = {}
    if isinstance(deploy_files, list):
        for item in deploy_files:
            if not isinstance(item, dict):
                continue
            md5 = item.get("package_md5") or item.get("source_md5")
            if not isinstance(md5, str) or not md5:
                continue
            rel = _norm_path(item.get("relative_path"))
            install_rel = _norm_path(item.get("install_relative_path"))
            if rel:
                result[rel] = md5
                result[f"media/audio/{rel}"] = md5
            if install_rel:
                result[install_rel] = md5
    return result


def _package_md5s_from_items(items: object) -> Dict[str, str]:
    result: Dict[str, str] = {}
    if not isinstance(items, list):
        return result
    for item in items:
        if not isinstance(item, dict):
            continue
        md5 = item.get("md5")
        if not isinstance(md5, str) or not md5:
            continue
        rel = _norm_path(item.get("relative_path"))
        install_rel = _norm_path(item.get("install_relative_path"))
        if rel:
            result[rel] = md5
            result[f"media/audio/{rel}"] = md5
        if install_rel:
            result[install_rel] = md5
    return result


def _package_md5s_by_path(manifest_path: Optional[Path]) -> Dict[str, str]:
    if not manifest_path or not manifest_path.exists():
        return {}
    manifest = load_manifest(manifest_path)
    return _package_md5s_from_items(manifest.get("package_files"))


def _package_file_count(manifest_path: Optional[Path]) -> int:
    if not manifest_path or not manifest_path.exists():
        return 0
    manifest = load_manifest(manifest_path)
    files = manifest.get("package_files")
    return len(files) if isinstance(files, list) else 0


def _baseline_install_relative_path(item: Dict[str, object]) -> str:
    install_rel = _norm_path(item.get("install_relative_path"))
    if install_rel:
        return install_rel
    rel = _norm_path(item.get("relative_path"))
    if not rel:
        return ""
    if rel.startswith("media/") or rel == "UserPreferredLang":
        return rel
    if item.get("scope") == "string_table":
        return f"media/Stripped/StringTables/{rel}"
    return f"media/audio/{rel}"


def _baseline_md5_for(item: Dict[str, object]) -> Optional[str]:
    md5 = item.get("recorded_baseline_md5") or item.get("backup_md5")
    return md5 if isinstance(md5, str) and md5 else None


def _package_diff_status_for(item: Dict[str, object], package_md5: Optional[str]) -> str:
    if not package_md5:
        return "missing"
    baseline_md5 = _baseline_md5_for(item)
    if not baseline_md5:
        return "unknown"
    return "modified" if package_md5 != baseline_md5 else "unchanged"


def _coverage_status_for(item: Dict[str, object], package_md5: Optional[str]) -> str:
    if not package_md5:
        return "unchecked"
    if item.get("package_diff_status") == "unchanged":
        if item.get("baseline_status") == "ok":
            return "original"
        if item.get("baseline_status") in {"not_backed_up", "backup_missing"}:
            return "unchecked"
        return "changed"
    if item.get("md5") == package_md5:
        return "covered"
    if item.get("baseline_status") == "ok":
        return "original"
    if item.get("baseline_status") in {"not_backed_up", "backup_missing"}:
        return "unchecked"
    return "changed"


def _apply_package_coverage(
    plan: Dict[str, object],
    package_md5s: Dict[str, str],
    last_applied_md5s: Optional[Dict[str, str]] = None,
) -> None:
    last_applied_md5s = last_applied_md5s or {}
    for item in list(plan.get("files", [])):
        if not isinstance(item, dict):
            continue
        install_rel = _norm_path(item.get("install_relative_path"))
        short_rel = install_rel
        prefix = "media/audio/"
        if short_rel.startswith(prefix):
            short_rel = short_rel[len(prefix) :]
        package_md5 = package_md5s.get(install_rel) or package_md5s.get(short_rel)
        last_applied_md5 = last_applied_md5s.get(install_rel) or last_applied_md5s.get(short_rel)
        item["package_md5"] = package_md5
        item["last_applied_package_md5"] = last_applied_md5
        item["package_diff_status"] = _package_diff_status_for(item, package_md5)
        item["coverage_status"] = _coverage_status_for(item, package_md5)


def _issue(label: str, path: str, detail: str, level: str) -> Dict[str, str]:
    return {
        "label": label,
        "path": path,
        "detail": detail,
        "level": level,
    }


def _changed_file_set_reason(
    files: List[Dict[str, object]], *, build_changed: bool
) -> Optional[str]:
    added = any(item.get("baseline_status") == "not_backed_up" for item in files)
    removed = any(
        item.get("exists") is False and item.get("baseline_status") == "backup_differs_from_current"
        for item in files
    )
    prefix = "game_update" if build_changed else "external_conflict"
    if added and removed:
        return f"{prefix}_file_set_changed"
    if added:
        return f"{prefix}_file_added"
    if removed:
        return f"{prefix}_file_removed"
    return None


def _integrity_from_plan(
    plan: Dict[str, object],
    *,
    baseline_manifest: Optional[Path],
    pending_baseline_manifest: Optional[Path],
    package_manifest: Optional[Path],
    last_applied_package_manifest: Optional[Path],
    package_file_count: int,
) -> Dict[str, object]:
    files = [
        item
        for item in list(plan.get("files", []))
        if isinstance(item, dict)
        and not is_baseline_derived_index_path(item.get("relative_path"))
        and not is_baseline_derived_index_path(item.get("install_relative_path"))
    ]
    pending_md5s = _manifest_md5s_by_path(pending_baseline_manifest)
    baseline_manifest_data = _load_manifest_if_exists(baseline_manifest)
    current_game_version = plan.get("game_version")
    current_game_version_id = baseline_version_id(current_game_version)
    baseline_build_compatible = (
        baseline_supports_game_version(baseline_manifest_data, current_game_version)
        if baseline_manifest_data
        else True
    )
    baseline_supported_ids = baseline_supported_version_ids(baseline_manifest_data)
    build_changed = bool(baseline_manifest_data) and not baseline_build_compatible
    file_set_reason = (
        _changed_file_set_reason(files, build_changed=build_changed)
        if baseline_manifest_data
        else None
    )
    issues: List[Dict[str, str]] = []
    checked = 0
    package_matches = 0
    last_applied_matches = 0
    baseline_matches = 0
    pending_matches = 0
    changed = 0
    unknown = 0

    def add_unknown(label: str, path: str, detail: str) -> None:
        nonlocal unknown
        unknown += 1
        issues.append(_issue(label, path, detail, "unknown"))

    if package_manifest is None:
        if baseline_manifest and files:
            for item in files:
                rel = _baseline_install_relative_path(item)
                current_md5 = item.get("md5")
                baseline_md5 = _baseline_md5_for(item)
                if item.get("baseline_status") == "not_backed_up":
                    add_unknown(
                        rel or "原始备份",
                        str(item.get("source_game_path") or ""),
                        "当前游戏多出了原始备份未记录的受保护文件。",
                    )
                    continue
                if not rel or not current_md5 or not baseline_md5:
                    detail = (
                        "当前游戏缺少原始备份记录中的受保护文件。"
                        if item.get("exists") is False
                        else "原始备份记录缺少路径或校验码。"
                    )
                    add_unknown(
                        rel or "原始备份",
                        str(item.get("source_game_path") or baseline_manifest),
                        detail,
                    )
                    continue
                checked += 1
                pending_md5 = pending_md5s.get(rel)
                last_applied_md5 = item.get("last_applied_package_md5")
                matched = False
                if pending_md5 and current_md5 == pending_md5:
                    pending_matches += 1
                    matched = True
                if isinstance(last_applied_md5, str) and current_md5 == last_applied_md5:
                    last_applied_matches += 1
                    matched = True
                if current_md5 == baseline_md5:
                    baseline_matches += 1
                    matched = True
                if matched:
                    continue
                changed += 1
                issues.append(
                    _issue(
                        rel,
                        str(item.get("source_game_path") or ""),
                        "当前文件不属于原始备份、新文件记录或上次写入包；还没有准备包可用来判定是否已写入。",
                        "game_changed" if build_changed else "external_conflict",
                    )
                )
            if changed > 0:
                level = "game_changed" if build_changed else "external_conflict"
            elif pending_baseline_manifest and pending_matches == checked and checked > 0:
                level = "pending_verify"
            elif last_applied_package_manifest and last_applied_matches == checked and checked > 0:
                level = "previous_package_applied"
            elif file_set_reason:
                level = "game_changed" if build_changed else "external_conflict"
            elif build_changed and baseline_matches == checked and checked > 0:
                level = "build_bump_available"
            elif baseline_matches == checked and checked > 0:
                level = "no_package"
            elif unknown > 0:
                level = "unknown"
            else:
                level = "no_package"
        else:
            level = "no_package"
        return {
            "level": level,
            "checked_files": checked,
            "package_matches": 0,
            "last_applied_package_matches": last_applied_matches,
            "baseline_matches": baseline_matches,
            "pending_baseline_matches": pending_matches,
            "changed_files": changed,
            "unknown_files": unknown,
            "package_files": 0,
            "baseline_manifest_path": (
                str(baseline_manifest.resolve()) if baseline_manifest else None
            ),
            "pending_baseline_manifest_path": (
                str(pending_baseline_manifest.resolve()) if pending_baseline_manifest else None
            ),
            "package_manifest_path": None,
            "last_applied_package_manifest_path": (
                str(last_applied_package_manifest.resolve())
                if last_applied_package_manifest
                else None
            ),
            "current_game_version_id": current_game_version_id,
            "baseline_build_compatible": baseline_build_compatible,
            "baseline_supported_game_version_ids": baseline_supported_ids,
            "reason": file_set_reason,
            "issues": issues[:6],
        }

    package_items = [
        item
        for item in files
        if isinstance(item.get("package_md5"), str) and str(item.get("package_md5"))
    ]
    if not package_items:
        add_unknown("包记录", str(package_manifest), "包记录缺少文件校验。")
    if baseline_manifest is None:
        return {
            "level": "no_baseline",
            "checked_files": 0,
            "package_matches": 0,
            "last_applied_package_matches": 0,
            "baseline_matches": 0,
            "pending_baseline_matches": 0,
            "changed_files": 0,
            "unknown_files": unknown,
            "package_files": package_file_count,
            "baseline_manifest_path": None,
            "pending_baseline_manifest_path": (
                str(pending_baseline_manifest.resolve()) if pending_baseline_manifest else None
            ),
            "package_manifest_path": str(package_manifest.resolve()),
            "last_applied_package_manifest_path": (
                str(last_applied_package_manifest.resolve())
                if last_applied_package_manifest
                else None
            ),
            "current_game_version_id": current_game_version_id,
            "baseline_build_compatible": baseline_build_compatible,
            "baseline_supported_game_version_ids": baseline_supported_ids,
            "issues": issues[:6],
        }

    for item in package_items:
        rel = _baseline_install_relative_path(item)
        current_md5 = item.get("md5")
        package_md5 = item.get("package_md5")
        if item.get("baseline_status") == "not_backed_up":
            add_unknown(
                rel or "原始备份",
                str(item.get("source_game_path") or ""),
                "当前游戏多出了原始备份未记录的受保护文件。",
            )
            continue
        if not rel or not current_md5 or not package_md5:
            detail = (
                "当前游戏缺少准备包记录中的受保护文件。"
                if item.get("exists") is False
                else "包内文件缺少路径或校验码。"
            )
            add_unknown(
                rel or "包记录", str(item.get("source_game_path") or package_manifest), detail
            )
            continue
        checked += 1
        baseline_md5 = _baseline_md5_for(item)
        pending_md5 = pending_md5s.get(rel)
        last_applied_md5 = item.get("last_applied_package_md5")
        matched = False
        if current_md5 == package_md5:
            package_matches += 1
            matched = True
        if isinstance(last_applied_md5, str) and current_md5 == last_applied_md5:
            last_applied_matches += 1
            matched = True
        if baseline_md5 and current_md5 == baseline_md5:
            baseline_matches += 1
            matched = True
        if pending_md5 and current_md5 == pending_md5:
            pending_matches += 1
            matched = True
        if matched:
            continue
        changed += 1
        issues.append(
            _issue(
                rel,
                str(item.get("source_game_path") or ""),
                "当前文件不属于原始备份、新文件记录、准备包或上次写入包。",
                "game_changed" if build_changed else "external_conflict",
            )
        )

    if changed > 0:
        level = "game_changed" if build_changed else "external_conflict"
    elif (
        pending_baseline_manifest
        and (pending_matches == checked or package_matches == checked)
        and checked > 0
    ):
        level = "pending_verify"
    elif file_set_reason:
        level = "game_changed" if build_changed else "external_conflict"
    elif package_matches == checked and checked > 0:
        level = "package_applied"
    elif last_applied_package_manifest and last_applied_matches == checked and checked > 0:
        level = "previous_package_applied"
    elif build_changed and baseline_matches == checked and checked > 0:
        level = "build_bump_available"
    elif baseline_matches == checked and checked > 0:
        level = "baseline"
    elif unknown > 0:
        level = "unknown"
    else:
        level = "game_changed" if build_changed else "external_conflict"
    return {
        "level": level,
        "checked_files": checked,
        "package_matches": package_matches,
        "last_applied_package_matches": last_applied_matches,
        "baseline_matches": baseline_matches,
        "pending_baseline_matches": pending_matches,
        "changed_files": changed,
        "unknown_files": unknown,
        "package_files": package_file_count,
        "baseline_manifest_path": str(baseline_manifest.resolve()) if baseline_manifest else None,
        "pending_baseline_manifest_path": (
            str(pending_baseline_manifest.resolve()) if pending_baseline_manifest else None
        ),
        "package_manifest_path": str(package_manifest.resolve()),
        "last_applied_package_manifest_path": (
            str(last_applied_package_manifest.resolve()) if last_applied_package_manifest else None
        ),
        "current_game_version_id": current_game_version_id,
        "baseline_build_compatible": baseline_build_compatible,
        "baseline_supported_game_version_ids": baseline_supported_ids,
        "reason": file_set_reason,
        "issues": issues[:6],
    }


def verify_integrity(
    game_dir: Path,
    *,
    package_dir: Optional[str] = None,
    baseline_manifest: Optional[Path] = None,
    pending_baseline_manifest: Optional[Path] = None,
    last_applied_package_manifest: Optional[Path] = None,
    preferred_path: Optional[str] = None,
    jobs: int = 0,
    progress_jsonl: bool = False,
) -> Dict[str, object]:
    package_manifest = _package_manifest_path(package_dir)
    package_md5s = _package_md5s_by_path(package_manifest)
    last_applied_md5s = _last_applied_md5s_by_path(last_applied_package_manifest)
    plan = baseline_plan(
        game_dir,
        None,
        baseline_manifest,
        jobs=jobs,
        progress_jsonl=progress_jsonl,
        allow_missing=True,
        preferred_path=preferred_path,
    )
    _apply_package_coverage(plan, package_md5s, last_applied_md5s)
    return {
        "schema_version": 1,
        "kind": "file_integrity",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "baseline_plan": plan,
        "integrity": _integrity_from_plan(
            plan,
            baseline_manifest=baseline_manifest,
            pending_baseline_manifest=pending_baseline_manifest,
            package_manifest=package_manifest,
            last_applied_package_manifest=last_applied_package_manifest,
            package_file_count=_package_file_count(package_manifest),
        ),
    }


def print_integrity(payload: Dict[str, object]) -> None:
    integrity = payload.get("integrity") if isinstance(payload.get("integrity"), dict) else {}
    plan = payload.get("baseline_plan") if isinstance(payload.get("baseline_plan"), dict) else {}
    print(f"Status : {integrity.get('level')}")
    print(f"Files  : {integrity.get('checked_files')} checked · {plan.get('file_count')} protected")
    print(f"准备包记录: {integrity.get('package_manifest_path') or '(none)'}")
    print(f"上次写入记录: {integrity.get('last_applied_package_manifest_path') or '(none)'}")
    print(f"原始备份记录: {integrity.get('baseline_manifest_path') or '(none)'}")
    print(f"新文件记录: {integrity.get('pending_baseline_manifest_path') or '(none)'}")
    for issue in list(integrity.get("issues", [])):
        if not isinstance(issue, dict):
            continue
        print(f"  [{issue.get('level')}] {issue.get('label')}: {issue.get('detail')}")


def cmd_verify_integrity(args: argparse.Namespace) -> int:
    game_dir = resolve_game_dir(args.game_dir)
    baseline_manifest = _resolve_existing_path(args.baseline_manifest)
    pending_baseline_manifest = _resolve_existing_path(args.pending_baseline_manifest)
    last_applied_package_manifest = _resolve_existing_path(args.last_applied_package_manifest)
    payload = verify_integrity(
        game_dir,
        package_dir=args.package_dir,
        baseline_manifest=baseline_manifest,
        pending_baseline_manifest=pending_baseline_manifest,
        last_applied_package_manifest=last_applied_package_manifest,
        preferred_path=args.preferred_path,
        jobs=args.jobs,
        progress_jsonl=args.progress_jsonl,
    )
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_integrity(payload)
    return 0
