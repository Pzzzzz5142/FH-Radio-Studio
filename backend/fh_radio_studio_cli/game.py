from __future__ import annotations

from .common import *
from .fsb5 import parse_fsb5

FH6_STEAM_APP_ID = "2483190"
TRACK_BANK_SUFFIX_PREFERENCE = ("CU1", "CU2", "Disk", "PDLC1", "PDLC2")


def candidate_game_dirs() -> Iterable[Path]:
    env = os.environ.get("FH6_GAME_DIR")
    if env:
        yield Path(env)
    yield DEFAULT_STEAM_GAME_DIR


def audio_dir_for(path: Path) -> Path:
    if (path / "RadioInfo_CN.xml").exists() and (path / "FMODBanks").is_dir():
        return path
    return path / "media" / "audio"


def resolve_game_dir(raw: Optional[str]) -> Path:
    if raw:
        path = Path(raw).expanduser()
        audio = audio_dir_for(path)
        if audio.is_dir():
            return path
        die(f"Game/audio directory not found: {path}")

    for candidate in candidate_game_dirs():
        if audio_dir_for(candidate).is_dir():
            return candidate

    die(
        "Could not find FH6. Pass --game-dir or set FH6_GAME_DIR. "
        f"Tried {DEFAULT_STEAM_GAME_DIR}"
    )


def game_root_for(path: Path) -> Path:
    audio = audio_dir_for(path)
    if audio == path and path.name.lower() == "audio" and path.parent.name.lower() == "media":
        return path.parent.parent
    return path


def steam_game_version(game_dir: Path) -> Dict[str, object]:
    root = game_root_for(game_dir)
    manifest = steam_appmanifest_for(root)
    if not manifest:
        return {
            "source": "unknown",
            "version_id": "unknown",
        }

    values = parse_steam_appmanifest(manifest)
    app_id = values.get("appid") or FH6_STEAM_APP_ID
    build_id = values.get("buildid")
    last_updated_raw = values.get("LastUpdated") or values.get("lastupdated")
    last_updated_epoch = safe_int(last_updated_raw, 0) if last_updated_raw else None
    last_updated_at = (
        datetime.fromtimestamp(last_updated_epoch, timezone.utc).isoformat()
        if last_updated_epoch
        else None
    )
    version_id = f"steam-b{build_id}" if build_id else f"steam-app{app_id}"
    return {
        "source": "steam",
        "version_id": version_id,
        "app_id": app_id,
        "build_id": build_id,
        "name": values.get("name"),
        "install_dir": values.get("installdir"),
        "content_updated_at": last_updated_at,
        "content_updated_epoch": last_updated_epoch,
        "manifest_path": str(manifest.resolve()),
    }


def steam_appmanifest_for(game_root: Path) -> Optional[Path]:
    steamapps_dirs: List[Path] = []
    for path in [game_root, *game_root.parents]:
        if path.name.lower() == "steamapps":
            steamapps_dirs.append(path)
        if path.name.lower() == "common" and path.parent.name.lower() == "steamapps":
            steamapps_dirs.append(path.parent)

    seen: set[str] = set()
    for steamapps in steamapps_dirs:
        key = path_key(steamapps)
        if key in seen:
            continue
        seen.add(key)
        manifest = steamapps / f"appmanifest_{FH6_STEAM_APP_ID}.acf"
        if manifest.exists():
            return manifest
    return None


def parse_steam_appmanifest(path: Path) -> Dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    result: Dict[str, str] = {}
    for key, value in re.findall(r'"([^"]+)"\s+"([^"]*)"', text):
        if key not in result:
            result[key] = value
    return result


def radio_info_files(audio_dir: Path) -> List[Path]:
    return sorted(audio_dir.glob("RadioInfo_*.xml"))


def default_radio_info(audio_dir: Path) -> Path:
    # Pick a deterministic representative XML for station/bank topology only.
    # Package builds still patch every RadioInfo_*.xml; this is not UserPreferredLang.
    preferred = audio_dir / "RadioInfo_CN.xml"
    if preferred.exists():
        return preferred
    preferred = audio_dir / "RadioInfo_EN.xml"
    if preferred.exists():
        return preferred
    files = radio_info_files(audio_dir)
    if not files:
        die(f"No RadioInfo_*.xml files found in {audio_dir}")
    return files[0]


def parse_xml(path: Path) -> ET.ElementTree:
    try:
        return ET.parse(path)
    except ET.ParseError as exc:
        die(f"XML parse failed for {path}: {exc}")


def find_station(root: ET.Element, radio: int) -> ET.Element:
    stations = root.find("RadioStations")
    if stations is None:
        die("RadioStations element not found")
    for station in stations.findall("RadioStation"):
        if station.get("Number") == str(radio):
            return station
    die(f"Radio station R{radio} not found")


def find_child_by_attr(parent: ET.Element, tag: str, attr: str, value: str) -> Optional[ET.Element]:
    for child in parent.findall(tag):
        if child.get(attr) == value:
            return child
    return None


def track_bank_names(station: ET.Element) -> List[str]:
    banks = station.find("Banks")
    if banks is None:
        return []
    return [
        name
        for bank in banks.findall("Bank")
        for name in [(bank.get("Name") or "").strip()]
        if name and "Tracks" in name
    ]


def bank_path_for_name(audio_dir: Path, name: str) -> Path:
    filename = name if name.endswith(".assets.bank") else f"{name}.assets.bank"
    return audio_dir / "FMODBanks" / filename


def track_bank_details(station: ET.Element, audio_dir: Path) -> List[Dict[str, object]]:
    names = track_bank_names(station)
    seen = set(names)
    fmod_dir = audio_dir / "FMODBanks"
    radio_number = safe_int(station.get("Number"))
    if radio_number > 0 and fmod_dir.is_dir():
        for path in sorted(fmod_dir.glob(f"R{radio_number}_Tracks_*.assets.bank")):
            name = path.name.removesuffix(".assets.bank")
            if name not in seen:
                names.append(name)
                seen.add(name)

    details: List[Dict[str, object]] = []
    for name in names:
        path = bank_path_for_name(audio_dir, name)
        detail: Dict[str, object] = {
            "name": name,
            "path": str(path),
            "exists": path.exists(),
            "slots": None,
            "error": None,
        }
        if path.exists():
            try:
                detail["slots"] = parse_fsb5(path).num_samples
            except CliError as exc:
                detail["error"] = str(exc)
        details.append(detail)
    return details


def target_track_bank_detail(
    details: List[Dict[str, object]],
    radio_number: Optional[int] = None,
) -> Optional[Dict[str, object]]:
    if radio_number is not None:
        own_prefix = f"R{radio_number}_"
        details = [
            detail for detail in details if str(detail.get("name", "")).startswith(own_prefix)
        ]
        if not details:
            return None
    usable = [
        detail
        for detail in details
        if isinstance(detail.get("slots"), int) and int(detail["slots"]) > 0
    ]
    for suffix in TRACK_BANK_SUFFIX_PREFERENCE:
        for detail in usable:
            if str(detail.get("name", "")).endswith(f"_{suffix}"):
                return detail
    if usable:
        return usable[0]
    for detail in details:
        if detail.get("exists"):
            return detail
    return details[0] if details else None


def radio_code_for_station(radio: int, name: str) -> str:
    if radio > 0:
        return f"R{radio}"
    normalized = name.strip()
    return normalized if normalized else "R?"


def legacy_radio_code_for_station(radio: int, name: str) -> Optional[str]:
    normalized = name.lower()
    if "horizon pulse" in normalized:
        return "HOR"
    if "bass arena" in normalized:
        return "BAS"
    if "block party" in normalized:
        return "BLK"
    if "eurobeat" in normalized:
        return "EUR"
    if "rocas" in normalized:
        return "ROC"
    if normalized == "xs" or "horizon xs" in normalized:
        return "XS"
    if "timeless" in normalized:
        return "TIM"
    if "mixmaster" in normalized:
        return "MIX"
    return None


def station_summary(station: ET.Element, audio_dir: Optional[Path] = None) -> Dict[str, object]:
    track_list = find_child_by_attr(station, "SampleList", "Type", "Track")
    banks = station.find("Banks")
    playlists = {
        playlist.get("Type", "?"): len(playlist.findall("Entry"))
        for playlist in station.findall("PlayList")
    }
    number = safe_int(station.get("Number"))
    name = station.get("Name", "")
    summary: Dict[str, object] = {
        "number": number,
        "name": name,
        "radio_code": radio_code_for_station(number, name),
        "banks": (
            [bank.get("Name", "") for bank in banks.findall("Bank")] if banks is not None else []
        ),
        "tracks": len(track_list.findall("Sample")) if track_list is not None else 0,
        "playlists": playlists,
    }
    if audio_dir is not None:
        details = track_bank_details(station, audio_dir)
        target = target_track_bank_detail(details, safe_int(station.get("Number")))
        bank_slots = target.get("slots") if target else None
        summary.update(
            {
                "track_banks": details,
                "target_bank_name": target.get("name") if target else None,
                "target_bank_path": target.get("path") if target else None,
                "bank_slots": bank_slots if isinstance(bank_slots, int) else None,
                "replaceable_slots": bank_slots if isinstance(bank_slots, int) else None,
            }
        )
    return summary


def iter_track_samples(station: ET.Element) -> Iterable[ET.Element]:
    track_list = find_child_by_attr(station, "SampleList", "Type", "Track")
    if track_list is None:
        return []
    return track_list.findall("Sample")


def print_station_table(stations: Iterable[ET.Element], audio_dir: Optional[Path] = None) -> None:
    print(f"{'R':>3}  {'Station':<24} {'XML':>5}  {'Bank':>5}  {'Free':>5}  {'Event':>5}  Banks")
    print("-" * 96)
    for station in stations:
        info = station_summary(station, audio_dir)
        playlists = info["playlists"]
        banks = ", ".join(info["banks"])
        bank_slots = info.get("bank_slots")
        bank_text = str(bank_slots) if isinstance(bank_slots, int) else "?"
        print(
            f"R{info['number']:<2}  {info['name']:<24} {info['tracks']:>5}  "
            f"{bank_text:>5}  "
            f"{playlists.get('FreeRoam', 0):>5}  {playlists.get('Event', 0):>5}  {banks}"
        )


def is_forza_running() -> bool:
    if os.name != "nt":
        return False
    try:
        result = subprocess.run(
            ["tasklist", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except Exception:
        return False
    if result.returncode != 0:
        return False
    return any("forzahorizon6" in line.lower() for line in result.stdout.splitlines())


def cmd_probe(args: argparse.Namespace) -> int:
    game_dir = resolve_game_dir(args.game_dir)
    audio_dir = audio_dir_for(game_dir)
    fmod_dir = audio_dir / "FMODBanks"
    files = radio_info_files(audio_dir)
    banks = sorted(fmod_dir.glob("R*_Tracks*.assets.bank")) if fmod_dir.is_dir() else []

    print(f"Game dir : {game_dir}")
    print(f"Audio dir: {audio_dir}")
    print(f"RadioInfo: {len(files)} file(s)")
    for path in files:
        print(f"  - {path.name}")
    print(f"FMODBanks: {len(banks)} track bank(s)")
    for path in banks[:16]:
        print(f"  - {path.name}")
    if len(banks) > 16:
        print(f"  ... {len(banks) - 16} more")

    info_path = default_radio_info(audio_dir)
    root = parse_xml(info_path).getroot()
    stations = root.find("RadioStations")
    if stations is None:
        die(f"No RadioStations in {info_path}")
    print(f"\nStations from {info_path.name}:")
    print_station_table(stations.findall("RadioStation"), audio_dir)
    return 0


def cmd_list_radios(args: argparse.Namespace) -> int:
    audio_dir: Optional[Path] = None
    if args.radio_info:
        info_path = Path(args.radio_info)
        candidate_audio_dir = info_path.parent
        if (candidate_audio_dir / "FMODBanks").is_dir():
            audio_dir = candidate_audio_dir
    else:
        game_dir = resolve_game_dir(args.game_dir)
        audio_dir = audio_dir_for(game_dir)
        info_path = default_radio_info(audio_dir)

    root = parse_xml(info_path).getroot()
    stations_parent = root.find("RadioStations")
    if stations_parent is None:
        die(f"No RadioStations in {info_path}")

    stations = stations_parent.findall("RadioStation")
    if args.radio:
        stations = [find_station(root, args.radio)]
    print(f"RadioInfo: {info_path}")
    print_station_table(stations, audio_dir)

    if args.tracks:
        for station in stations:
            print(f"\nR{station.get('Number')} {station.get('Name')}")
            for index, sample in enumerate(iter_track_samples(station), start=1):
                length = safe_int(sample.get("SampleLength"))
                print(
                    f"  {index:02d}. {sample.get('SoundName')} | "
                    f"{sample.get('Artist', '?')} - {sample.get('DisplayName', '?')} | "
                    f"{s2tc(length, safe_int(sample.get('SampleRate'), TARGET_SAMPLE_RATE))}"
                )
    return 0
