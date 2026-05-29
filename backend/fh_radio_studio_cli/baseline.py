from __future__ import annotations

from concurrent.futures import ProcessPoolExecutor, as_completed
from time import perf_counter

from .baseline_order import is_baseline_derived_index_path, write_baseline_bank_order_index
from .common import *
from .game import audio_dir_for, resolve_game_dir, steam_game_version
from .package import collect_package_deploy_files, package_audio_dir

PROGRESS_PREFIX = "FH_RADIO_STUDIO_PROGRESS "
_PARALLEL_HASH_THRESHOLD_BYTES = 64 * 1024 * 1024
_OLD_BASELINE_BUILD_LIMIT = 5


def baseline_manifest_path(root: Path) -> Path:
    return root / "baseline_manifest.json"


def _project_root_from_baseline_dir(baseline_dir: Path) -> Optional[Path]:
    if baseline_dir.parent.name != "backups":
        return None
    project_root = baseline_dir.parent.parent
    return project_root if project_root != baseline_dir.parent else None


def _clear_prepared_packages_for_overwrite(baseline_dir: Path) -> List[Path]:
    project_root = _project_root_from_baseline_dir(baseline_dir)
    if project_root is None:
        return []
    packages_root = project_root / "packages"
    metadata_root = project_root / ".fh-radio-studio"
    targets = [
        packages_root / "current",
        packages_root / "pending",
        metadata_root / "last_applied_package_manifest.json",
    ]
    cleared: List[Path] = []
    for target in targets:
        if target.is_dir():
            shutil.rmtree(target)
            cleared.append(target)
        elif target.is_file():
            target.unlink()
            cleared.append(target)
    return cleared


def _emit_progress(enabled: bool, payload: Dict[str, object]) -> None:
    if not enabled:
        return
    print(
        PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        file=sys.stderr,
        flush=True,
    )


def _hash_file_worker(path_text: str) -> Tuple[str, Optional[str], Optional[str]]:
    path = Path(path_text)
    try:
        return path_text, md5_file(path), None
    except Exception as exc:
        return path_text, None, f"{type(exc).__name__}: {exc}"


def _hash_worker_count(requested: int, task_count: int, total_bytes: int) -> int:
    if task_count <= 1:
        return 1
    if requested > 0:
        return max(1, min(requested, task_count))
    if total_bytes < _PARALLEL_HASH_THRESHOLD_BYTES:
        return 1
    cpu_count = os.cpu_count() or 1
    auto_workers = max(1, cpu_count // 2)
    return max(1, min(auto_workers, task_count))


def _hash_paths(
    paths: Iterable[Path],
    *,
    jobs: int = 0,
    progress_jsonl: bool = False,
    step_id: str = "baseline.hash",
    label: str = "并行 MD5",
) -> Dict[str, Optional[str]]:
    tasks: List[Dict[str, object]] = []
    seen: set[str] = set()
    for raw_path in paths:
        if raw_path is None:
            continue
        path = raw_path.expanduser()
        key = path_key(path)
        if key in seen:
            continue
        seen.add(key)
        tasks.append(
            {
                "key": key,
                "path": str(path),
                "size": file_size(path) or 0,
            }
        )

    total_files = len(tasks)
    total_bytes = sum(int(task["size"]) for task in tasks)
    worker_count = _hash_worker_count(jobs, total_files, total_bytes)
    _emit_progress(
        progress_jsonl,
        {
            "event": "plan",
            "steps": [
                {
                    "id": step_id,
                    "label": label,
                    "detail": f"{total_files} 个文件 · {total_bytes} bytes · {worker_count} worker(s)",
                    "weight": max(total_files, 1),
                }
            ],
        },
    )
    if not tasks:
        return {}

    _emit_progress(
        progress_jsonl,
        {
            "event": "step_started",
            "step_id": step_id,
            "total_files": total_files,
            "total_bytes": total_bytes,
            "jobs": worker_count,
        },
    )
    started = perf_counter()
    completed_files = 0
    completed_bytes = 0
    results: Dict[str, Optional[str]] = {}

    def record(task: Dict[str, object], md5: Optional[str], error: Optional[str] = None) -> None:
        nonlocal completed_files, completed_bytes
        completed_files += 1
        completed_bytes += int(task["size"])
        results[str(task["key"])] = md5
        event: Dict[str, object] = {
            "event": "hash_completed",
            "step_id": step_id,
            "path": str(task["path"]),
            "size": int(task["size"]),
            "completed_files": completed_files,
            "total_files": total_files,
            "completed_bytes": completed_bytes,
            "total_bytes": total_bytes,
            "runtime_ms": int((perf_counter() - started) * 1000),
        }
        if error:
            event["error"] = error
        _emit_progress(progress_jsonl, event)

    try:
        if worker_count <= 1:
            for task in tasks:
                _, digest, error = _hash_file_worker(str(task["path"]))
                record(task, digest, error)
        else:
            with ProcessPoolExecutor(max_workers=worker_count) as pool:
                futures = {
                    pool.submit(_hash_file_worker, str(task["path"])): task for task in tasks
                }
                for future in as_completed(futures):
                    task = futures[future]
                    try:
                        _, digest, error = future.result()
                    except Exception as exc:
                        digest = None
                        error = f"{type(exc).__name__}: {exc}"
                    record(task, digest, error)
    except KeyboardInterrupt:
        _emit_progress(
            progress_jsonl,
            {
                "event": "step_failed",
                "step_id": step_id,
                "summary": "cancelled",
                "runtime_ms": int((perf_counter() - started) * 1000),
            },
        )
        raise

    _emit_progress(
        progress_jsonl,
        {
            "event": "step_completed",
            "step_id": step_id,
            "status": "done",
            "summary": f"{completed_files}/{total_files} files hashed",
            "runtime_ms": int((perf_counter() - started) * 1000),
            "total_bytes": total_bytes,
            "jobs": worker_count,
        },
    )
    return results


def _path_from_install_relative(root: Path, relative_path: str) -> Optional[Path]:
    normalized = relative_path.replace("\\", "/").strip("/")
    if not normalized:
        return None
    return root / Path(*normalized.split("/"))


def resolve_baseline_backup_path(
    manifest_path: Path,
    item: Dict[str, object],
) -> Optional[Path]:
    """Resolve a baseline file from the current baseline directory layout."""
    install_rel = str(item.get("install_relative_path") or "").replace("\\", "/")
    if not install_rel:
        return None
    return _path_from_install_relative(manifest_path.parent, install_rel)


def _rewrite_manifest_backup_paths(
    manifest: Dict[str, object],
    manifest_path: Path,
) -> None:
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict):
            continue
        if item.get("manifest_only"):
            item.pop("backup_path", None)
            continue
        backup_path = resolve_baseline_backup_path(manifest_path, item)
        if backup_path:
            item["backup_path"] = str(backup_path.resolve())


def load_baseline_md5s(path: Optional[str]) -> Dict[str, str]:
    if not path:
        return {}
    manifest_path = Path(path).expanduser()
    if not manifest_path.exists():
        die(f"Baseline manifest not found: {manifest_path}")
    manifest = load_manifest(manifest_path)
    result: Dict[str, str] = {}
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict):
            continue
        rel = str(item.get("relative_path") or "").replace("\\", "/")
        install_rel = str(item.get("install_relative_path") or "").replace("\\", "/")
        if is_baseline_derived_index_path(rel) or is_baseline_derived_index_path(install_rel):
            continue
        md5 = item.get("md5")
        if isinstance(md5, str) and md5:
            if rel:
                result[rel] = md5
            if install_rel:
                result[install_rel] = md5
    return result


def baseline_version_id(game_version: object) -> str:
    if isinstance(game_version, dict):
        raw = game_version.get("version_id")
        if isinstance(raw, str) and raw.strip():
            return sanitize_token(raw, "unknown").lower().replace("_", "-")
        build_id = game_version.get("build_id")
        if isinstance(build_id, str) and build_id.strip():
            return f"steam-b{sanitize_token(build_id, 'unknown').lower()}"
    return "unknown"


def baseline_supported_version_ids(manifest: Dict[str, object]) -> List[str]:
    result: List[str] = []

    def add(value: object) -> None:
        if not isinstance(value, str):
            return
        normalized = sanitize_token(value, "unknown").lower().replace("_", "-")
        if normalized and normalized != "unknown" and normalized not in result:
            result.append(normalized)

    add(manifest.get("game_version_id"))
    add(baseline_version_id(manifest.get("game_version")))
    raw_supported = manifest.get("supported_game_version_ids")
    if isinstance(raw_supported, list):
        for item in raw_supported:
            add(item)
    return result


def baseline_supports_game_version(manifest: Dict[str, object], game_version: object) -> bool:
    current_id = baseline_version_id(game_version)
    if current_id == "unknown":
        return True
    supported = baseline_supported_version_ids(manifest)
    return not supported or current_id in supported


def add_supported_game_version_id(manifest: Dict[str, object], game_version: object) -> bool:
    current_id = baseline_version_id(game_version)
    if current_id == "unknown":
        die("Current Steam build id is unknown; cannot update baseline compatibility.")
    supported = baseline_supported_version_ids(manifest)
    changed = current_id not in supported
    if changed:
        supported.append(current_id)
    manifest["supported_game_version_ids"] = supported
    return changed


def baseline_backup_name(state: str, game_version: object) -> str:
    state_id = sanitize_token(state, "baseline").lower().replace("_", "-")
    return f"fh6-{baseline_version_id(game_version)}-baseline-{state_id}"


def _normalize_game_version_id(value: object) -> Optional[str]:
    if not isinstance(value, str) or not value.strip():
        return None
    normalized = sanitize_token(value, "unknown").lower().replace("_", "-")
    return normalized if normalized and normalized != "unknown" else None


def _old_baseline_version_id(path: Path, manifest: Optional[Dict[str, object]]) -> str:
    if manifest:
        for key in ("archive_game_version_id", "game_version_id"):
            normalized = _normalize_game_version_id(manifest.get(key))
            if normalized:
                return normalized
        normalized = _normalize_game_version_id(baseline_version_id(manifest.get("game_version")))
        if normalized:
            return normalized

    match = re.match(r"^fh6-(.+)-baseline-old-\d{8}_\d{6}(?:-\d+)?$", path.name)
    if match:
        normalized = _normalize_game_version_id(match.group(1))
        if normalized:
            return normalized
    return "unknown"


def _parse_manifest_time(value: object) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _old_baseline_last_used_at(path: Path, manifest: Optional[Dict[str, object]]) -> datetime:
    if manifest:
        for key in ("archived_at", "promoted_at", "created_at"):
            try:
                parsed = _parse_manifest_time(manifest.get(key))
            except ValueError:
                parsed = None
            if parsed:
                return parsed

    match = re.match(r"^fh6-.+-baseline-old-(\d{8}_\d{6})(?:-\d+)?$", path.name)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y%m%d_%H%M%S").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)


def _load_old_baseline_manifest(path: Path) -> Optional[Dict[str, object]]:
    manifest_path = baseline_manifest_path(path)
    if not manifest_path.exists():
        return None
    try:
        payload = load_manifest(manifest_path)
    except CliError:
        return None
    return payload if isinstance(payload, dict) else None


def _is_old_baseline_archive(path: Path, manifest: Optional[Dict[str, object]]) -> bool:
    if not path.is_dir():
        return False
    if re.match(r"^fh6-.+-baseline-old-\d{8}_\d{6}(?:-\d+)?$", path.name):
        return True
    return bool(manifest and manifest.get("kind") == "game_baseline")


def _old_baseline_archive_dir(
    old_root: Path,
    version_id: str,
    stamp: str,
) -> Path:
    base = old_root / f"fh6-{version_id}-baseline-old-{stamp}"
    if not base.exists():
        return base
    for suffix in range(2, 1000):
        candidate = old_root / f"{base.name}-{suffix}"
        if not candidate.exists():
            return candidate
    die(f"Could not choose a unique old baseline directory under {old_root}")


def _mark_old_baseline_archived(
    old_dir: Path,
    version_id: str,
    archived_at: datetime,
) -> None:
    manifest_path = baseline_manifest_path(old_dir)
    if not manifest_path.exists():
        return
    try:
        manifest = load_manifest(manifest_path)
    except CliError:
        return
    manifest["archived_at"] = archived_at.isoformat()
    manifest["archive_game_version_id"] = version_id
    write_json(manifest_path, manifest)


def _prune_old_baselines_by_build_id(
    old_root: Path,
    *,
    keep_builds: int = _OLD_BASELINE_BUILD_LIMIT,
) -> List[Path]:
    if keep_builds <= 0 or not old_root.exists():
        return []

    entries: List[Tuple[str, datetime, str, Path]] = []
    for child in old_root.iterdir():
        manifest = _load_old_baseline_manifest(child)
        if not _is_old_baseline_archive(child, manifest):
            continue
        entries.append(
            (
                _old_baseline_version_id(child, manifest),
                _old_baseline_last_used_at(child, manifest),
                child.name,
                child,
            )
        )

    entries.sort(key=lambda item: (item[1], item[2]), reverse=True)
    kept_versions: set[str] = set()
    removed: List[Path] = []
    for version_id, _, _, path in entries:
        if version_id not in kept_versions and len(kept_versions) < keep_builds:
            kept_versions.add(version_id)
            continue
        shutil.rmtree(path)
        removed.append(path)
    return removed


def describe_game_version(game_version: object) -> str:
    if not isinstance(game_version, dict):
        return "unknown"
    if game_version.get("source") == "steam":
        app_id = game_version.get("app_id") or "?"
        build_id = game_version.get("build_id") or "?"
        updated = game_version.get("content_updated_at") or "unknown update time"
        return f"Steam app {app_id} · build {build_id} · updated {updated}"
    return str(game_version.get("version_id") or "unknown")


def collect_game_baseline_file_specs(
    game_dir: Path,
    *,
    preferred_path: Optional[str] = None,
) -> List[Dict[str, object]]:
    audio_dir = audio_dir_for(game_dir)
    specs: List[Dict[str, object]] = []
    for xml in sorted(audio_dir.glob("RadioInfo_*.xml")):
        specs.append(
            {
                "source": xml,
                "scope": "radio_info",
                "relative_path": xml.name,
                "install_relative_path": str(Path("media") / "audio" / xml.name).replace("\\", "/"),
            }
        )
    bank_dir = audio_dir / "FMODBanks"
    if bank_dir.is_dir():
        for bank in sorted(bank_dir.glob("R*_Tracks*.assets.bank")):
            specs.append(
                {
                    "source": bank,
                    "scope": "radio_bank",
                    "relative_path": str(Path("FMODBanks") / bank.name).replace("\\", "/"),
                    "install_relative_path": str(
                        Path("media") / "audio" / "FMODBanks" / bank.name
                    ).replace("\\", "/"),
                }
            )
    string_tables = game_dir / "media" / "Stripped" / "StringTables"
    if string_tables.is_dir():
        for table in sorted(string_tables.glob("*.zip")):
            specs.append(
                {
                    "source": table,
                    "scope": "string_table",
                    "relative_path": table.name,
                    "install_relative_path": str(
                        Path("media") / "Stripped" / "StringTables" / table.name
                    ).replace("\\", "/"),
                }
            )
    if not specs:
        die(
            f"No baselineable RadioInfo_*.xml or FMODBanks/R*_Tracks*.assets.bank found in {audio_dir}"
        )
    return specs


def collect_package_baseline_file_specs(
    audio_dir: Path,
    package_audio: Path,
    *,
    preferred_path: Optional[str] = None,
) -> List[Dict[str, object]]:
    game_dir = audio_dir.parent.parent
    package_root = (
        package_audio.parent.parent
        if package_audio.name == "audio" and package_audio.parent.name == "media"
        else package_audio
    )
    specs: List[Dict[str, object]] = []
    for item in collect_package_deploy_files(package_root):
        package_src = Path(str(item["source"]))
        rel_text = str(item["relative_path"]).replace("\\", "/")
        install_rel_text = str(item["install_relative_path"]).replace("\\", "/")
        specs.append(
            {
                "source": game_dir / Path(*install_rel_text.split("/")),
                "scope": item.get("kind", "package_file"),
                "relative_path": rel_text,
                "install_relative_path": install_rel_text,
                "package_path": package_src,
            }
        )
    return specs


def load_baseline_items_by_install_path(path: Optional[Path]) -> Dict[str, Dict[str, object]]:
    if not path or not path.exists():
        return {}
    manifest = load_manifest(path)
    result: Dict[str, Dict[str, object]] = {}
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict):
            continue
        rel = str(item.get("relative_path") or "").replace("\\", "/")
        install_rel = str(item.get("install_relative_path") or "").replace("\\", "/")
        if is_baseline_derived_index_path(rel) or is_baseline_derived_index_path(install_rel):
            continue
        key = install_rel or (f"media/audio/{rel}" if rel else "")
        if key:
            result[key] = item
    return result


def baseline_plan(
    game_dir: Path,
    package_audio: Optional[Path] = None,
    baseline_manifest: Optional[Path] = None,
    *,
    preferred_path: Optional[str] = None,
    jobs: int = 0,
    progress_jsonl: bool = False,
    allow_missing: bool = False,
) -> Dict[str, object]:
    audio_dir = audio_dir_for(game_dir)
    game_version = steam_game_version(game_dir)
    baseline_items = load_baseline_items_by_install_path(baseline_manifest)
    specs = (
        collect_package_baseline_file_specs(audio_dir, package_audio, preferred_path=preferred_path)
        if package_audio
        else collect_game_baseline_file_specs(game_dir, preferred_path=preferred_path)
    )
    if allow_missing and not package_audio:
        known_install_paths = {
            str(item["install_relative_path"]).replace("\\", "/")
            for item in specs
            if item.get("install_relative_path")
        }
        for install_rel, item in baseline_items.items():
            if install_rel in known_install_paths:
                continue
            rel_text = str(item.get("relative_path") or install_rel).replace("\\", "/")
            scope = str(item.get("scope") or "baseline_file")
            specs.append(
                {
                    "source": game_dir / Path(*install_rel.split("/")),
                    "scope": scope,
                    "relative_path": rel_text,
                    "install_relative_path": install_rel,
                }
            )
            known_install_paths.add(install_rel)
    hash_inputs: List[Path] = []
    resolved_backup_paths: Dict[str, Optional[Path]] = {}
    for spec in specs:
        source = Path(str(spec["source"]))
        if not source.exists():
            if not allow_missing:
                die(f"Game file missing; cannot baseline: {source}")
        else:
            hash_inputs.append(source)
        package_path = spec.get("package_path")
        if package_path:
            hash_inputs.append(Path(str(package_path)))
        install_rel = str(spec["install_relative_path"])
        backup_item = baseline_items.get(install_rel)
        backup_path = (
            resolve_baseline_backup_path(baseline_manifest, backup_item)
            if backup_item and baseline_manifest
            else None
        )
        resolved_backup_paths[install_rel] = backup_path
        if backup_path:
            hash_inputs.append(backup_path)

    hashes = _hash_paths(
        hash_inputs,
        jobs=jobs,
        progress_jsonl=progress_jsonl,
        step_id="baseline.hash",
        label="校验 FH Radio Studio 保护文件",
    )
    files = []
    by_scope: Dict[str, int] = {}
    by_status: Dict[str, int] = {}
    total_size = 0
    for spec in specs:
        source = Path(str(spec["source"]))
        size = file_size(source) or 0
        total_size += size
        scope = str(spec["scope"])
        by_scope[scope] = by_scope.get(scope, 0) + 1
        install_rel = str(spec["install_relative_path"])
        backup_item = baseline_items.get(install_rel)
        backup_path = resolved_backup_paths.get(install_rel)
        backup_md5 = hashes.get(path_key(backup_path)) if backup_path else None
        recorded_md5 = (
            str(backup_item.get("md5")) if backup_item and backup_item.get("md5") else None
        )
        current_md5 = hashes.get(path_key(source)) if source.exists() else None
        package_path = Path(str(spec["package_path"])) if spec.get("package_path") else None
        package_md5 = hashes.get(path_key(package_path)) if package_path else None
        if backup_item is None:
            baseline_status = "not_backed_up"
        elif not backup_path or not backup_path.exists():
            baseline_status = "backup_missing"
        elif recorded_md5 and backup_md5 != recorded_md5:
            baseline_status = "backup_changed"
        elif backup_md5 != current_md5:
            baseline_status = "backup_differs_from_current"
        else:
            baseline_status = "ok"
        by_status[baseline_status] = by_status.get(baseline_status, 0) + 1
        file_item: Dict[str, object] = {
            "scope": scope,
            "relative_path": str(spec["relative_path"]),
            "install_relative_path": install_rel,
            "source_game_path": str(source.resolve()),
            "exists": source.exists(),
            "size": size,
            "md5": current_md5,
            "baseline_status": baseline_status,
            "backup_path": (
                str(backup_path.resolve()) if backup_path and backup_path.exists() else None
            ),
            "backup_md5": backup_md5,
            "recorded_baseline_md5": recorded_md5,
            "package_path": str(package_path.resolve()) if package_path else None,
            "package_md5": package_md5,
        }
        files.append(file_item)
    return {
        "schema_version": 1,
        "kind": "baseline_plan",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game_dir": str(game_dir),
        "audio_dir": str(audio_dir),
        "game_version": game_version,
        "game_version_id": baseline_version_id(game_version),
        "package_audio": str(package_audio.resolve()) if package_audio else None,
        "file_count": len(files),
        "total_size": total_size,
        "by_scope": by_scope,
        "by_status": by_status,
        "baseline_manifest": str(baseline_manifest.resolve()) if baseline_manifest else None,
        "files": files,
    }


def print_baseline_plan(plan: Dict[str, object]) -> None:
    print(f"Game dir  : {plan['game_dir']}")
    print(f"Audio dir : {plan['audio_dir']}")
    print(f"Version   : {describe_game_version(plan.get('game_version'))}")
    print(f"Package   : {plan['package_audio'] or '(none; full FH Radio Studio baseline)'}")
    print(f"Files     : {plan['file_count']}")
    print("Scopes:")
    for scope, count in sorted(dict(plan.get("by_scope", {})).items()):
        print(f"  {scope}: {count}")
    print("Plan:")
    for item in list(plan.get("files", [])):
        if not isinstance(item, dict):
            continue
        print(
            f"  [{item.get('scope')}] {item.get('install_relative_path')}  "
            f"status={item.get('baseline_status')}  md5={item.get('md5')}  size={item.get('size')}"
        )


def cmd_baseline(args: argparse.Namespace) -> int:
    if args.baseline_action == "plan":
        game_dir = resolve_game_dir(args.game_dir)
        package_audio = (
            package_audio_dir(Path(args.package_dir).expanduser()) if args.package_dir else None
        )
        baseline_manifest = (
            Path(args.baseline_manifest).expanduser() if args.baseline_manifest else None
        )
        plan = baseline_plan(
            game_dir,
            package_audio,
            baseline_manifest,
            preferred_path=args.preferred_path,
            jobs=args.jobs,
            progress_jsonl=args.progress_jsonl,
        )
        if args.json:
            print(json.dumps(plan, ensure_ascii=False, indent=2))
        else:
            print_baseline_plan(plan)
        return 0

    if args.baseline_action == "create":
        game_dir = resolve_game_dir(args.game_dir)
        audio_dir = audio_dir_for(game_dir)
        package_audio = (
            package_audio_dir(Path(args.package_dir).expanduser()) if args.package_dir else None
        )
        out_dir = Path(args.out_dir).expanduser()
        manifest_path = baseline_manifest_path(out_dir)
        plan = baseline_plan(
            game_dir,
            package_audio,
            preferred_path=args.preferred_path,
            jobs=args.jobs,
            progress_jsonl=args.progress_jsonl,
        )
        game_version = plan.get("game_version", {})
        files = [item for item in list(plan.get("files", [])) if isinstance(item, dict)]

        if manifest_path.exists() and not args.overwrite:
            die(f"Baseline already exists: {manifest_path}")

        print(f"Game audio : {audio_dir}")
        print(f"Game build : {describe_game_version(game_version)}")
        print(
            f"Package    : {package_audio if package_audio else '(none; full FH Radio Studio baseline)'}"
        )
        print(f"Baseline   : {out_dir}")
        print(f"Name       : {baseline_backup_name(args.state, game_version)}")
        print(f"State      : {args.state}")
        print("Plan:")
        for item in files:
            print(f"  {item['source_game_path']} -> {out_dir / item['install_relative_path']}")

        if not args.yes:
            print("\nDry run only. Re-run with --yes to create the baseline.")
            return 0

        if out_dir.exists() and args.overwrite:
            shutil.rmtree(out_dir)
        if args.overwrite and args.state == "current":
            for cleared in _clear_prepared_packages_for_overwrite(out_dir):
                print(f"  cleared package artifact {cleared}")
        manifest_files = []
        for item in files:
            rel_text = str(item["relative_path"]).replace("\\", "/")
            install_rel_text = str(item["install_relative_path"]).replace("\\", "/")
            game_src = Path(str(item["source_game_path"]))
            if not game_src.exists():
                die(f"Game file missing; cannot baseline: {game_src}")
            manifest_item: Dict[str, object] = {
                "relative_path": rel_text,
                "install_relative_path": install_rel_text,
                "scope": item.get("scope"),
                "source_game_path": str(game_src.resolve()),
                "md5": item.get("md5"),
                "package_path": item.get("package_path"),
                "package_md5": item.get("package_md5"),
            }
            backup = out_dir / Path(*install_rel_text.split("/"))
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(game_src, backup)
            manifest_item["backup_path"] = str(backup.resolve())
            manifest_item["size"] = file_size(backup)
            manifest_files.append(manifest_item)
            print(f"  saved {install_rel_text}")

        manifest_data: Dict[str, object] = {
            "schema_version": 1,
            "kind": "game_baseline",
            "state": args.state,
            "backup_name": baseline_backup_name(args.state, game_version),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "game_dir": str(game_dir),
            "audio_dir": str(audio_dir),
            "game_version": game_version,
            "game_version_id": baseline_version_id(game_version),
            "supported_game_version_ids": [baseline_version_id(game_version)],
            "package_audio": str(package_audio.resolve()) if package_audio else None,
            "file_count": len(manifest_files),
            "by_scope": plan.get("by_scope", {}),
            "files": manifest_files,
        }
        bank_order_index = write_baseline_bank_order_index(out_dir, manifest_data)
        if bank_order_index:
            manifest_data["derived_indexes"] = {"bank_order": bank_order_index}
            print(
                "Derived bank order index: "
                f"{out_dir / str(bank_order_index['relative_path'])} "
                f"({bank_order_index['ok_bank_count']}/{bank_order_index['bank_count']} banks matched)"
            )

        write_json(manifest_path, manifest_data)
        print(f"Baseline manifest: {manifest_path}")
        return 0

    if args.baseline_action == "promote":
        current_dir = Path(args.current_dir).expanduser()
        pending_dir = Path(args.pending_dir).expanduser()
        old_root = Path(args.old_root).expanduser()
        target_current_dir = (
            Path(args.target_current_dir).expanduser()
            if getattr(args, "target_current_dir", None)
            else current_dir
        )
        pending_manifest = baseline_manifest_path(pending_dir)
        if not pending_manifest.exists():
            die(f"Pending baseline not found: {pending_manifest}")
        old_version_id = "unknown"
        current_manifest = baseline_manifest_path(current_dir)
        if current_manifest.exists():
            current_manifest_data = load_manifest(current_manifest)
            old_version_id = baseline_version_id(current_manifest_data.get("game_version"))
        archived_at = datetime.now(timezone.utc)
        old_dir = _old_baseline_archive_dir(
            old_root,
            old_version_id,
            datetime.now().strftime("%Y%m%d_%H%M%S"),
        )

        print(f"Current baseline : {current_dir}")
        print(f"Pending baseline : {pending_dir}")
        print(f"Target current   : {target_current_dir}")
        print(f"Old baseline     : {old_dir}")
        if not args.yes:
            print("\nDry run only. Re-run with --yes to promote pending baseline.")
            return 0

        old_root.mkdir(parents=True, exist_ok=True)
        if current_dir.exists():
            shutil.move(str(current_dir), str(old_dir))
            _mark_old_baseline_archived(old_dir, old_version_id, archived_at)
        pending_manifest_data = load_manifest(pending_manifest)
        pending_manifest_data["state"] = "current"
        pending_manifest_data["backup_name"] = baseline_backup_name(
            "current", pending_manifest_data.get("game_version")
        )
        pending_manifest_data["game_version_id"] = baseline_version_id(
            pending_manifest_data.get("game_version")
        )
        pending_manifest_data["supported_game_version_ids"] = [
            pending_manifest_data["game_version_id"]
        ]
        pending_manifest_data["promoted_at"] = datetime.now(timezone.utc).isoformat()
        shutil.move(str(pending_dir), str(target_current_dir))
        target_manifest = baseline_manifest_path(target_current_dir)
        _rewrite_manifest_backup_paths(pending_manifest_data, target_manifest)
        write_json(target_manifest, pending_manifest_data)
        pruned_old = _prune_old_baselines_by_build_id(old_root)
        if pruned_old:
            print(
                "Old baseline LRU: "
                f"removed {len(pruned_old)} archived baseline(s); "
                f"keeping the latest {_OLD_BASELINE_BUILD_LIMIT} Steam build id(s)."
            )
        print(f"Promoted pending baseline to: {target_current_dir}")
        return 0

    if args.baseline_action == "discard-pending":
        pending_dir = Path(args.pending_dir).expanduser()
        print(f"Pending baseline : {pending_dir}")
        if not args.yes:
            print("\nDry run only. Re-run with --yes to delete pending baseline.")
            return 0
        if pending_dir.exists():
            shutil.rmtree(pending_dir)
        print("Pending baseline removed.")
        return 0

    if args.baseline_action == "apply":
        game_dir = resolve_game_dir(args.game_dir)
        audio_dir = audio_dir_for(game_dir)
        game_version = steam_game_version(game_dir)
        baseline_dir = Path(args.baseline_dir).expanduser()
        manifest_path = baseline_manifest_path(baseline_dir)
        if not manifest_path.exists():
            die(f"Baseline manifest not found: {manifest_path}")
        manifest = load_manifest(manifest_path)
        baseline_game_version = manifest.get("game_version")
        game_build = baseline_version_id(game_version)
        if game_build != "unknown" and not baseline_supports_game_version(manifest, game_version):
            die(
                "Steam build mismatch: "
                f"game is {describe_game_version(game_version)}, "
                f"baseline is {describe_game_version(baseline_game_version)}"
            )
        files = [
            item
            for item in list(manifest.get("files", []))
            if isinstance(item, dict)
            and not is_baseline_derived_index_path(item.get("relative_path"))
            and not is_baseline_derived_index_path(item.get("install_relative_path"))
        ]
        if not files:
            die(f"Baseline has no files: {manifest_path}")

        print(f"Game audio : {audio_dir}")
        print(f"Baseline   : {baseline_dir}")
        print(f"Game build : {describe_game_version(game_version)}")
        print(f"Baseline   : {describe_game_version(baseline_game_version)}")
        print(
            "Restore warning: this will overwrite game files directly. "
            "No additional backup or restore log will be created."
        )
        print("Plan:")
        for item in files:
            rel_text = str(item.get("relative_path") or "").replace("\\", "/")
            install_rel_text = str(item.get("install_relative_path") or "").replace("\\", "/")
            if not rel_text:
                die(f"Baseline entry is missing relative_path in {manifest_path}")
            source_preview = (
                baseline_dir / Path(*install_rel_text.split("/"))
                if install_rel_text
                else baseline_dir / "media" / "audio" / Path(*rel_text.split("/"))
            )
            dest_preview = (
                game_dir / Path(*install_rel_text.split("/"))
                if install_rel_text
                else audio_dir / Path(*rel_text.split("/"))
            )
            print(f"  {source_preview} -> {dest_preview}")

        if not args.yes:
            print(
                "\nDry run only. Re-run with --yes to copy baseline files into the game directory."
            )
            return 0

        for item in files:
            rel_text = str(item.get("relative_path") or "").replace("\\", "/")
            install_rel_text = str(item.get("install_relative_path") or "").replace("\\", "/")
            if not rel_text:
                die(f"Baseline entry is missing relative_path in {manifest_path}")
            rel = Path(*rel_text.split("/"))
            saved = resolve_baseline_backup_path(manifest_path, item)
            if not saved or not saved.exists():
                die(f"Baseline file missing: {saved}")
            expected_md5 = item.get("md5")
            saved_md5 = md5_file(saved)
            if isinstance(expected_md5, str) and expected_md5 and saved_md5 != expected_md5:
                die(
                    f"Baseline MD5 mismatch for {rel_text}: expected {expected_md5}, got {saved_md5}"
                )
            dest = (
                game_dir / Path(*install_rel_text.split("/"))
                if install_rel_text
                else audio_dir / rel
            )
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(saved, dest)
            print(f"  applied {rel_text}")

        print("Baseline applied. No backup or restore log was created.")
        return 0

    if args.baseline_action == "bump-build":
        game_dir = resolve_game_dir(args.game_dir)
        game_version = steam_game_version(game_dir)
        manifest_path = Path(args.manifest).expanduser()
        if not manifest_path.exists():
            die(f"Baseline manifest not found: {manifest_path}")
        manifest = load_manifest(manifest_path)
        if manifest.get("kind") != "game_baseline":
            die(f"Not a game baseline manifest: {manifest_path}")
        changed = add_supported_game_version_id(manifest, game_version)
        manifest["build_compatibility_updated_at"] = datetime.now(timezone.utc).isoformat()
        print(f"Baseline manifest : {manifest_path}")
        print(f"Game build        : {describe_game_version(game_version)}")
        print(f"Supported builds  : {', '.join(baseline_supported_version_ids(manifest))}")
        if not args.yes:
            print("\nDry run only. Re-run with --yes to update the baseline manifest.")
            return 0
        write_json(manifest_path, manifest)
        print(
            "Baseline build compatibility updated."
            if changed
            else "Baseline already supports this build."
        )
        return 0

    die(f"Unknown baseline action: {args.baseline_action}")
