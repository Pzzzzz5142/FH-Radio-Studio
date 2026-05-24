from __future__ import annotations

from .common import *
from .game import (
    audio_dir_for,
    find_child_by_attr,
    find_station,
    parse_xml,
    radio_info_files,
    resolve_game_dir,
)


def build_sample_element(manifest: Dict[str, object]) -> ET.Element:
    sample = ET.Element(
        "Sample",
        {
            "SoundName": str(manifest["sound_name"]),
            "SampleLength": str(manifest["sample_length"]),
            "SampleRate": str(manifest["sample_rate"]),
            "DisplayName": str(manifest["display_name"]),
            "Artist": str(manifest["artist"]),
            "IsXCloudModeSafe": "false",
        },
    )
    markers = manifest["markers"]
    for name in MARKER_ORDER:
        ET.SubElement(sample, "Marker", {"Name": name, "Position": str(markers.get(name, -1))})
    for loop_name, start, end in LOOPS:
        ET.SubElement(sample, "Loop", {"Name": loop_name, "StartMarker": start, "EndMarker": end})
    bpm = manifest.get("bpm") or [{"Value": "0", "Start": "-1"}]
    for bpm_item in bpm:
        ET.SubElement(
            sample,
            "BPM",
            {"Value": str(bpm_item.get("Value", "0")), "Start": str(bpm_item.get("Start", "-1"))},
        )
    return sample


def element_to_string(element: ET.Element) -> str:
    copy = deepcopy(element)
    ET.indent(copy, space="  ")
    return ET.tostring(copy, encoding="unicode")


def patch_xml_tree(
    tree: ET.ElementTree, manifest: Dict[str, object], playlist_mode: str
) -> Dict[str, int]:
    root = tree.getroot()
    station = find_station(root, int(manifest["radio"]))
    track_list = find_child_by_attr(station, "SampleList", "Type", "Track")
    if track_list is None:
        die(f"R{manifest['radio']} has no Track SampleList")

    sound_name = str(manifest["sound_name"])
    sample = build_sample_element(manifest)
    replaced = 0
    appended = 0

    for index, child in enumerate(list(track_list)):
        if child.tag == "Sample" and child.get("SoundName") == sound_name:
            track_list.remove(child)
            track_list.insert(index, sample)
            replaced = 1
            break
    if not replaced:
        track_list.append(sample)
        appended = 1

    entries_added = 0
    entries_removed = 0
    for playlist in station.findall("PlayList"):
        if playlist.get("Type") not in PLAYLIST_TYPES:
            continue
        if playlist_mode == "only":
            for child in list(playlist):
                if child.tag == "Entry":
                    playlist.remove(child)
                    entries_removed += 1
        exists = any(child.tag == "Entry" and child.get("Name") == sound_name for child in playlist)
        if not exists:
            ET.SubElement(playlist, "Entry", {"Name": sound_name})
            entries_added += 1

    return {
        "sample_replaced": replaced,
        "sample_appended": appended,
        "playlist_entries_added": entries_added,
        "playlist_entries_removed": entries_removed,
    }


def set_marker(sample: ET.Element, name: str, position: int) -> None:
    value = str(int(position))
    sample.set(name, value)
    for marker in sample.findall("Marker"):
        if marker.get("Name") == name:
            marker.set("Position", value)
            return
    ET.SubElement(sample, "Marker", {"Name": name, "Position": value})


def patch_existing_sample(sample: ET.Element, assignment: Dict[str, object]) -> None:
    sample.set("SampleLength", str(assignment["sample_length"]))
    sample.set("SampleRate", str(assignment["sample_rate"]))
    sample.set("DisplayName", str(assignment["display_name"]))
    sample.set("Artist", str(assignment["artist"]))
    if "IsXCloudModeSafe" in sample.attrib:
        sample.set("IsXCloudModeSafe", "false")
    markers = assignment["markers"]
    for name in MARKER_ORDER:
        if name in markers:
            set_marker(sample, name, int(markers[name]))
    for loop_name, start, end in LOOPS:
        found = False
        for loop in sample.findall("Loop"):
            if loop.get("Name") == loop_name:
                loop.set("StartMarker", start)
                loop.set("EndMarker", end)
                found = True
                break
        if not found:
            ET.SubElement(
                sample, "Loop", {"Name": loop_name, "StartMarker": start, "EndMarker": end}
            )
    bpm_nodes = sample.findall("BPM")
    if bpm_nodes:
        bpm_nodes[0].set("Value", str(assignment.get("bpm", "0")))
        bpm_nodes[0].set("Start", bpm_nodes[0].get("Start", "-1"))
    else:
        ET.SubElement(sample, "BPM", {"Value": str(assignment.get("bpm", "0")), "Start": "-1"})


def patch_package_xml_tree(
    tree: ET.ElementTree, package: Dict[str, object], playlist_mode: str
) -> Dict[str, int]:
    if isinstance(package.get("radios"), list):
        totals = {
            "samples_patched": 0,
            "missing_samples": 0,
            "playlist_entries_added": 0,
            "playlist_entries_removed": 0,
        }
        for radio_package in package["radios"]:
            stats = _patch_single_package_xml_tree(tree, radio_package, playlist_mode)
            for key, value in stats.items():
                totals[key] += value
        return totals
    return _patch_single_package_xml_tree(tree, package, playlist_mode)


def _patch_single_package_xml_tree(
    tree: ET.ElementTree, package: Dict[str, object], playlist_mode: str
) -> Dict[str, int]:
    root = tree.getroot()
    station = find_station(root, int(package["radio"]))
    track_list = find_child_by_attr(station, "SampleList", "Type", "Track")
    if track_list is None:
        die(f"R{package['radio']} has no Track SampleList")

    assignments = list(package["assignments"])
    by_sound_name = {str(assignment["target_sound_name"]): assignment for assignment in assignments}
    patched = 0
    missing = 0
    for sample in track_list.findall("Sample"):
        sound_name = sample.get("SoundName", "")
        assignment = by_sound_name.get(sound_name)
        if not assignment:
            continue
        patch_existing_sample(sample, assignment)
        patched += 1

    for sound_name in by_sound_name:
        if not any(
            sample.get("SoundName") == sound_name for sample in track_list.findall("Sample")
        ):
            missing += 1

    entries_added = 0
    entries_removed = 0
    for playlist in station.findall("PlayList"):
        playlist_type = playlist.get("Type")
        if playlist_type not in PLAYLIST_TYPES:
            continue
        playlist_assignments = [
            assignment
            for assignment in assignments
            if bool(assignment.get("playlist_entry", False))
            and _assignment_in_playlist(assignment, playlist_type or "")
        ]
        if playlist_mode == "only" and playlist_assignments:
            for child in list(playlist):
                if child.tag == "Entry":
                    playlist.remove(child)
                    entries_removed += 1
        existing = {child.get("Name") for child in playlist.findall("Entry")}
        playlist_assignments.sort(
            key=lambda assignment: _assignment_playlist_slot(assignment, playlist_type or "")
        )
        playlist_sound_names = [
            str(assignment["target_sound_name"]) for assignment in playlist_assignments
        ]
        for sound_name in playlist_sound_names:
            if sound_name not in existing:
                ET.SubElement(playlist, "Entry", {"Name": sound_name})
                existing.add(sound_name)
                entries_added += 1

    return {
        "samples_patched": patched,
        "missing_samples": missing,
        "playlist_entries_added": entries_added,
        "playlist_entries_removed": entries_removed,
    }


def _assignment_in_playlist(assignment: Dict[str, object], playlist_type: str) -> bool:
    raw = assignment.get("playlist_types")
    if raw is None:
        return True
    if isinstance(raw, str):
        values = {raw}
    elif isinstance(raw, list):
        values = {str(value) for value in raw}
    else:
        return True
    return playlist_type in values


def _assignment_playlist_slot(assignment: Dict[str, object], playlist_type: str) -> int:
    raw_slots = assignment.get("playlist_slots")
    if isinstance(raw_slots, dict):
        raw = raw_slots.get(playlist_type)
        if raw is not None:
            try:
                return int(raw)
            except (TypeError, ValueError):
                pass
    try:
        return int(assignment.get("slot_index", 0)) + 1
    except (TypeError, ValueError):
        return 0


def cmd_patch_xml(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest).expanduser()
    manifest = load_manifest(manifest_path)
    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.radio_info:
        sources = [Path(args.radio_info).expanduser()]
    else:
        game_dir = resolve_game_dir(args.game_dir)
        sources = radio_info_files(audio_dir_for(game_dir))
    if not sources:
        die("No RadioInfo XML sources found")

    print(f"Manifest     : {manifest_path}")
    print(f"Output dir   : {out_dir}")
    print(f"Playlist mode: {args.playlist_mode}")

    totals = {
        "sample_replaced": 0,
        "sample_appended": 0,
        "playlist_entries_added": 0,
        "playlist_entries_removed": 0,
    }

    for source in sources:
        tree = parse_xml(source)
        stats = patch_xml_tree(tree, manifest, args.playlist_mode)
        for key, value in stats.items():
            totals[key] += value
        ET.indent(tree, space="  ")
        target = out_dir / source.name
        tree.write(str(target), encoding="utf-8", xml_declaration=True, short_empty_elements=True)
        parse_xml(target)
        print(f"  patched {source.name}: {stats}")

    print(f"Totals: {totals}")
    return 0
