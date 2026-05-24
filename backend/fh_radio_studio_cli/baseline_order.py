from __future__ import annotations

from .common import *
from .fsb5 import parse_fsb5
from .game import default_radio_info, find_station, iter_track_samples, parse_xml

BANK_ORDER_INDEX_RELATIVE_PATH = "derived/bank_order.json"


def baseline_bank_order_index_path(baseline_dir: Path) -> Path:
    return baseline_dir / Path(*BANK_ORDER_INDEX_RELATIVE_PATH.split("/"))


def is_baseline_derived_index_path(value: object) -> bool:
    normalized = str(value or "").replace("\\", "/").strip("/")
    return normalized.startswith("derived/")


def _path_from_install_relative(root: Path, relative_path: str) -> Path:
    return root / Path(*relative_path.replace("\\", "/").strip("/").split("/"))


def _baseline_audio_dir(baseline_dir: Path) -> Path:
    audio_dir = baseline_dir / "media" / "audio"
    return audio_dir if audio_dir.is_dir() else baseline_dir


def _radio_from_bank_name(name: str) -> Optional[int]:
    match = re.match(r"R(\d+)_Tracks_", name)
    if not match:
        return None
    return safe_int(match.group(1), 0) or None


def _track_sample_candidates(station: ET.Element) -> List[Dict[str, object]]:
    candidates: List[Dict[str, object]] = []
    for xml_index, sample in enumerate(iter_track_samples(station)):
        sound_name = (sample.get("SoundName") or "").strip()
        sample_length = safe_int(sample.get("SampleLength"), 0)
        sample_rate = safe_int(sample.get("SampleRate"), 0)
        if not sound_name or sample_length <= 0:
            continue
        candidates.append(
            {
                "xml_index": xml_index,
                "sound_name": sound_name,
                "sample_length": sample_length,
                "sample_rate": sample_rate,
                "display_name": sample.get("DisplayName") or "",
                "artist": sample.get("Artist") or "",
            }
        )
    return candidates


def _match_named_slots(bank_info: object) -> Optional[List[Dict[str, object]]]:
    names = [sample.name for sample in bank_info.samples]
    if not names or not all(names):
        return None
    return [
        {
            "bank_index": sample.index,
            "sound_name": sample.name,
            "bank_sample_count": int(sample.sample_count),
            "bank_frequency": int(sample.frequency),
            "match_method": "fsb_name_table",
            "length_delta": None,
            "xml_index": None,
            "sample_length": None,
            "sample_rate": None,
        }
        for sample in bank_info.samples
    ]


def _match_exact_length_slots(
    bank_info: object,
    candidates: List[Dict[str, object]],
) -> Tuple[Optional[List[Dict[str, object]]], List[str]]:
    warnings: List[str] = []
    used_xml_indexes: set[int] = set()
    slots: List[Dict[str, object]] = []
    for sample in bank_info.samples:
        matches: List[Dict[str, object]] = []
        for candidate in candidates:
            xml_index = int(candidate["xml_index"])
            if xml_index in used_xml_indexes:
                continue
            sample_rate = int(candidate["sample_rate"])
            if sample.frequency and sample_rate and int(sample.frequency) != sample_rate:
                continue
            if int(sample.sample_count) == int(candidate["sample_length"]):
                matches.append(candidate)
        if len(matches) != 1:
            warnings.append(
                f"bank_index={sample.index} sample_count={sample.sample_count} "
                f"matched {len(matches)} XML candidate(s)"
            )
            return None, warnings
        candidate = matches[0]
        used_xml_indexes.add(int(candidate["xml_index"]))
        slots.append(
            {
                "bank_index": sample.index,
                "sound_name": candidate["sound_name"],
                "xml_index": candidate["xml_index"],
                "sample_length": candidate["sample_length"],
                "sample_rate": candidate["sample_rate"],
                "bank_sample_count": int(sample.sample_count),
                "bank_frequency": int(sample.frequency),
                "length_delta": 0,
                "match_method": "exact_sample_length",
            }
        )
    return slots, warnings


def _bank_specs_from_manifest(
    baseline_dir: Path,
    manifest: Dict[str, object],
) -> List[Tuple[str, Path]]:
    specs: List[Tuple[str, Path]] = []
    for item in list(manifest.get("files", [])):
        if not isinstance(item, dict) or item.get("scope") != "radio_bank":
            continue
        install_rel = str(item.get("install_relative_path") or "").replace("\\", "/").strip("/")
        if not install_rel:
            continue
        path = _path_from_install_relative(baseline_dir, install_rel)
        name = Path(install_rel).name
        specs.append((name, path))
    return specs


def build_baseline_bank_order_index(
    baseline_dir: Path,
    manifest: Dict[str, object],
) -> Dict[str, object]:
    audio_dir = _baseline_audio_dir(baseline_dir)
    radio_info = default_radio_info(audio_dir)
    root = parse_xml(radio_info).getroot()
    banks: List[Dict[str, object]] = []
    warnings: List[str] = []

    for bank_name, bank_path in _bank_specs_from_manifest(baseline_dir, manifest):
        radio = _radio_from_bank_name(bank_name)
        if radio is None:
            warnings.append(f"{bank_name}: cannot infer radio number")
            continue
        try:
            station = find_station(root, radio)
        except CliError as exc:
            warnings.append(f"{bank_name}: {exc}")
            continue
        try:
            bank_info = parse_fsb5(bank_path)
        except CliError as exc:
            banks.append(
                {
                    "bank_name": bank_name,
                    "radio": radio,
                    "station": station.get("Name"),
                    "status": "unreadable",
                    "error": str(exc),
                    "slots": [],
                }
            )
            continue

        slots = _match_named_slots(bank_info)
        match_method = "fsb_name_table" if slots else ""
        bank_warnings: List[str] = []
        if slots is None:
            slots, bank_warnings = _match_exact_length_slots(
                bank_info,
                _track_sample_candidates(station),
            )
            match_method = "exact_sample_length" if slots else "unmatched"

        status = "ok" if slots and len(slots) == bank_info.num_samples else "unmatched"
        banks.append(
            {
                "bank_name": bank_name,
                "radio": radio,
                "station": station.get("Name"),
                "bank_slots": int(bank_info.num_samples),
                "status": status,
                "match_method": match_method,
                "warnings": bank_warnings,
                "slots": slots or [],
            }
        )
        warnings.extend(f"{bank_name}: {warning}" for warning in bank_warnings)

    ok_banks = [bank for bank in banks if bank.get("status") == "ok"]
    return {
        "schema_version": 1,
        "kind": "baseline_bank_order",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source_baseline_manifest": str(baseline_dir / "baseline_manifest.json"),
        "game_version_id": manifest.get("game_version_id"),
        "source_radio_info": (
            str(radio_info.relative_to(baseline_dir)).replace("\\", "/")
            if radio_info.is_relative_to(baseline_dir)
            else str(radio_info)
        ),
        "bank_count": len(banks),
        "ok_bank_count": len(ok_banks),
        "warnings": warnings,
        "banks": banks,
    }


def write_baseline_bank_order_index(
    baseline_dir: Path,
    manifest: Dict[str, object],
) -> Optional[Dict[str, object]]:
    try:
        index = build_baseline_bank_order_index(baseline_dir, manifest)
    except (CliError, OSError, ET.ParseError):
        return None
    if not index.get("banks"):
        return None
    path = baseline_bank_order_index_path(baseline_dir)
    write_json(path, index)
    return {
        "kind": "baseline_bank_order",
        "relative_path": BANK_ORDER_INDEX_RELATIVE_PATH,
        "size": file_size(path),
        "md5": md5_file(path),
        "bank_count": index.get("bank_count"),
        "ok_bank_count": index.get("ok_bank_count"),
    }


def ensure_baseline_bank_order_index(
    manifest_path: Path,
    manifest: Dict[str, object],
) -> Optional[Path]:
    index_path = _bank_order_path_from_manifest(manifest_path, manifest)
    if index_path:
        return index_path

    entry = write_baseline_bank_order_index(manifest_path.parent, manifest)
    if not entry:
        return None
    derived = manifest.get("derived_indexes")
    if not isinstance(derived, dict):
        derived = {}
    derived["bank_order"] = entry
    manifest["derived_indexes"] = derived
    write_json(manifest_path, manifest)
    return _bank_order_path_from_manifest(manifest_path, manifest)


def _bank_order_path_from_manifest(
    manifest_path: Path, manifest: Dict[str, object]
) -> Optional[Path]:
    derived = manifest.get("derived_indexes")
    entry = None
    if isinstance(derived, dict):
        raw_entry = derived.get("bank_order")
        if isinstance(raw_entry, dict):
            entry = raw_entry
    rel = (
        str(entry.get("relative_path") if entry else BANK_ORDER_INDEX_RELATIVE_PATH)
        .replace("\\", "/")
        .strip("/")
    )
    if not rel:
        return None
    path = manifest_path.parent / Path(*rel.split("/"))
    return path if path.exists() else None


def load_baseline_bank_order_names(
    baseline_manifest: Optional[str],
    bank_name: str,
    expected_slots: int,
) -> Optional[List[str]]:
    if not baseline_manifest:
        return None
    manifest_path = Path(baseline_manifest).expanduser()
    if not manifest_path.exists():
        return None
    manifest = load_manifest(manifest_path)
    index_path = ensure_baseline_bank_order_index(manifest_path, manifest)
    if not index_path:
        return None
    index = load_manifest(index_path)
    wanted = bank_name if bank_name.endswith(".assets.bank") else f"{bank_name}.assets.bank"
    for bank in list(index.get("banks", [])):
        if not isinstance(bank, dict):
            continue
        if bank.get("bank_name") != wanted or bank.get("status") != "ok":
            continue
        slots = [slot for slot in list(bank.get("slots", [])) if isinstance(slot, dict)]
        if len(slots) != expected_slots:
            return None
        slots.sort(key=lambda slot: safe_int(str(slot.get("bank_index")), -1))
        if [safe_int(str(slot.get("bank_index")), -1) for slot in slots] != list(
            range(expected_slots)
        ):
            return None
        names = [str(slot.get("sound_name") or "").strip() for slot in slots]
        if not all(names):
            return None
        return names
    return None
