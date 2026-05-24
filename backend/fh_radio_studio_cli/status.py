from __future__ import annotations

from .baseline import (
    baseline_version_id,
    load_baseline_items_by_install_path,
    resolve_baseline_backup_path,
)
from .common import *
from .external_tools import collect_tool_status
from .game import (
    audio_dir_for,
    default_radio_info,
    find_station,
    game_root_for,
    is_forza_running,
    parse_xml,
    resolve_game_dir,
    station_summary,
    steam_game_version,
)
from .language import (
    normalize_preferred_language,
    normalize_text_language,
    read_user_preferred_lang,
    resolve_user_preferred_lang_path,
    string_tables_dir_for,
)


def build_status_payload(args: argparse.Namespace) -> Dict[str, object]:
    resolved_game_dir = resolve_game_dir(args.game_dir)
    game_dir = game_root_for(resolved_game_dir)
    audio_dir = audio_dir_for(resolved_game_dir)
    game_version = steam_game_version(game_dir)
    radio_info = default_radio_info(audio_dir)

    root = parse_xml(radio_info).getroot()
    stations_parent = root.find("RadioStations")
    if stations_parent is None:
        die(f"No RadioStations in {radio_info}")

    station_elements = stations_parent.findall("RadioStation")
    radios = [station_summary(station, audio_dir) for station in station_elements]
    selected_radio = (
        station_summary(find_station(root, args.radio), audio_dir)
        if args.radio
        else (radios[0] if radios else None)
    )

    tools, tools_ok = collect_tool_status()
    preferred_path = resolve_user_preferred_lang_path(args.preferred_path)
    preferred_lang = read_user_preferred_lang(preferred_path)

    string_dir = string_tables_dir_for(game_dir)
    available_languages = sorted(path.stem.upper() for path in string_dir.glob("*.zip"))
    preferred_slot = normalize_preferred_language(preferred_lang) if preferred_lang else None
    baseline_manifest = (
        Path(args.baseline_manifest).expanduser() if args.baseline_manifest else None
    )
    baseline_items = load_baseline_items_by_install_path(baseline_manifest)

    current_table_md5s: Dict[str, Optional[str]] = {}
    for lang in available_languages:
        current_table_md5s[lang] = md5_file(string_dir / f"{lang}.zip")

    def infer_system_language() -> str:
        locale_name = (
            locale.getlocale()[0] or locale.getdefaultlocale()[0] or os.environ.get("LANG") or ""
        ).lower()
        candidates: List[str]
        if "zh" in locale_name and (
            "tw" in locale_name or "hk" in locale_name or "hant" in locale_name
        ):
            candidates = ["CHT", "CHS", "EN"]
        elif "zh" in locale_name:
            candidates = ["CHS", "CHT", "EN"]
        elif "ja" in locale_name:
            candidates = ["JP", "EN"]
        elif "ko" in locale_name:
            candidates = ["KO", "EN"]
        elif "fr" in locale_name:
            candidates = ["FR", "EN"]
        elif "de" in locale_name:
            candidates = ["DE", "EN"]
        elif "es" in locale_name:
            candidates = ["ES", "EN"]
        elif "it" in locale_name:
            candidates = ["IT", "EN"]
        elif "pt" in locale_name:
            candidates = ["PT", "EN"]
        else:
            candidates = ["EN", "GB", "CHS"]
        for candidate in candidates:
            if not available_languages or candidate in available_languages:
                return candidate
        return available_languages[0] if available_languages else "EN"

    def choose_language(candidate: Optional[str], fallbacks: List[Optional[str]]) -> str:
        normalized = normalize_text_language(candidate) if candidate else None
        if normalized and (not available_languages or normalized in available_languages):
            return normalized
        for fallback in fallbacks:
            normalized_fallback = normalize_text_language(fallback) if fallback else None
            if normalized_fallback and (
                not available_languages or normalized_fallback in available_languages
            ):
                return normalized_fallback
        return available_languages[0] if available_languages else (normalized or "CHS")

    def string_table_baseline_status(lang: str) -> Dict[str, object]:
        rel = str(Path("media") / "Stripped" / "StringTables" / f"{lang}.zip").replace("\\", "/")
        if not baseline_manifest or not baseline_manifest.exists():
            return {
                "status": "no_baseline",
                "verified": False,
                "install_relative_path": rel,
                "backup_path": None,
                "backup_md5": None,
                "recorded_md5": None,
            }
        item = baseline_items.get(rel)
        if not item:
            return {
                "status": "missing_entry",
                "verified": False,
                "install_relative_path": rel,
                "backup_path": None,
                "backup_md5": None,
                "recorded_md5": None,
            }
        backup_path = resolve_baseline_backup_path(baseline_manifest, item)
        backup_md5 = md5_file(backup_path) if backup_path else None
        recorded_md5 = str(item.get("md5")) if item.get("md5") else None
        if not backup_path or not backup_path.exists():
            status = "backup_missing"
            verified = False
        elif recorded_md5 and backup_md5 != recorded_md5:
            status = "backup_changed"
            verified = False
        else:
            status = "ok"
            verified = True
        return {
            "status": status,
            "verified": verified,
            "install_relative_path": rel,
            "backup_path": (
                str(backup_path.resolve()) if backup_path and backup_path.exists() else None
            ),
            "backup_md5": backup_md5,
            "recorded_md5": recorded_md5,
        }

    baseline_md5_by_lang: Dict[str, str] = {}
    for lang in available_languages:
        status = string_table_baseline_status(lang)
        recorded = status.get("recorded_md5")
        backup = status.get("backup_md5")
        md5 = recorded if isinstance(recorded, str) and recorded else backup
        if isinstance(md5, str) and md5:
            baseline_md5_by_lang[lang] = md5

    preferred_is_auto = preferred_slot is None or str(preferred_slot).lower() == "auto"
    effective_preferred_slot = infer_system_language() if preferred_is_auto else preferred_slot
    target_lang = choose_language(effective_preferred_slot, [args.target, "EN", "GB", "JP", "CHS"])
    target_path = string_dir / f"{target_lang}.zip"
    target_sha = sha256_file(target_path)
    target_md5 = md5_file(target_path)

    def detect_display_language() -> Tuple[str, str]:
        if target_md5:
            baseline_matches = [
                lang for lang, md5 in baseline_md5_by_lang.items() if md5 == target_md5
            ]
            if baseline_matches:
                preferred_matches = [lang for lang in baseline_matches if lang != target_lang]
                return (
                    preferred_matches[0] if preferred_matches else baseline_matches[0],
                    "baseline",
                )

            current_matches = [
                lang for lang, md5 in current_table_md5s.items() if md5 and md5 == target_md5
            ]
            if current_matches:
                preferred_matches = [lang for lang in current_matches if lang != target_lang]
                return (
                    preferred_matches[0] if preferred_matches else current_matches[0],
                    "current",
                )

        fallback = choose_language(args.source, [target_lang, "CHS"])
        return (fallback, "fallback")

    source_lang, display_detection = detect_display_language()
    source_path = string_dir / f"{source_lang}.zip"
    source_sha = sha256_file(source_path)
    source_md5 = md5_file(source_path)

    source_baseline = string_table_baseline_status(source_lang)
    target_baseline = string_table_baseline_status(target_lang)

    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "requested_game_dir": str(resolved_game_dir),
        "game_dir": str(game_dir),
        "game_version": game_version,
        "game_version_id": baseline_version_id(game_version),
        "audio_dir": str(audio_dir),
        "radio_info": str(radio_info),
        "game_running": is_forza_running(),
        "tools": tools,
        "tools_ok": tools_ok,
        "preferred_lang_path": str(preferred_path),
        "preferred_lang": preferred_lang,
        "language": {
            "string_tables_dir": str(string_dir),
            "source_lang": source_lang,
            "target_lang": target_lang,
            "source_path": str(source_path),
            "target_path": str(target_path),
            "source_exists": source_path.exists(),
            "target_exists": target_path.exists(),
            "source_sha256": source_sha,
            "target_sha256": target_sha,
            "source_md5": source_md5,
            "target_md5": target_md5,
            "target_matches_source": bool(source_sha and source_sha == target_sha),
            "available": available_languages,
            "display_detection": display_detection,
            "preferred_lang_effective": target_lang,
            "preferred_lang_source": "system" if preferred_is_auto else "file",
            "source_was_adjusted": (
                normalize_text_language(args.source) != source_lang if args.source else False
            ),
            "target_was_adjusted": (
                normalize_text_language(args.target) != target_lang if args.target else False
            ),
            "baseline_manifest": str(baseline_manifest.resolve()) if baseline_manifest else None,
            "source_baseline": source_baseline,
            "target_baseline": target_baseline,
            "voice_slot_verified": bool(target_baseline.get("verified")),
        },
        "radios": radios,
        "selected_radio": selected_radio,
    }


def cmd_status(args: argparse.Namespace) -> int:
    payload = build_status_payload(args)
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    language = payload["language"]
    selected = payload.get("selected_radio") or {}
    playlists = selected.get("playlists", {}) if isinstance(selected, dict) else {}
    preferred = payload.get("preferred_lang") or "<missing>"
    print("Dashboard status:")
    print(f"Game dir       : {payload['game_dir']}")
    print(f"Audio dir      : {payload['audio_dir']}")
    print(f"Game process   : {'running' if payload['game_running'] else 'not running'}")
    print(f"Tools          : {'ok' if payload['tools_ok'] else 'missing'}")
    if isinstance(language, dict):
        source = language.get("source_lang")
        target = language.get("target_lang")
        synced = "synced" if language.get("target_matches_source") else "not synced"
        verified = "verified" if language.get("voice_slot_verified") else "not verified"
        print(
            f"Language       : {source} display -> {target} voice ({synced}, {verified}), preferred {preferred}"
        )
    if isinstance(selected, dict):
        bank_slots = selected.get("bank_slots")
        bank_part = (
            f"{bank_slots} bank slots" if isinstance(bank_slots, int) else "bank slots unknown"
        )
        print(
            f"Selected radio : R{selected.get('number')} {selected.get('name')} | "
            f"{selected.get('tracks')} XML tracks | "
            f"{bank_part} | "
            f"Free/Event {playlists.get('FreeRoam', 0)}/{playlists.get('Event', 0)}"
        )
    return 0
