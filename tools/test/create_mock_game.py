from __future__ import annotations

import argparse
import json
import shutil
import struct
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUILD_ID = "99000001"
GAME_ROOT_REL = Path("steamapps") / "common" / "ForzaHorizon6"
PREFERRED_LANG_REL = Path("profile") / "ForzaHorizon6" / "UserPreferredLang"
FH6_STEAM_APP_ID = "2483190"

MARKER_ORDER = (
    "VeryStart",
    "TrackStart",
    "DJDrop",
    "TrackDrop",
    "TrackLoopStart",
    "TrackLoopEnd",
    "DJSegment",
    "PostDrop",
    "PostRaceLoopStart",
    "PostRaceLoopEnd",
    "StingerStart",
    "DJStart",
    "End",
    "Loop1Start",
    "Loop1End",
    "Loop2Start",
    "Loop2End",
    "Loop3Start",
    "Loop3End",
    "Loop4Start",
    "Loop4End",
    "Loop5Start",
    "Loop5End",
    "Section1",
    "Section2",
    "Section3",
    "Section4",
    "Section5",
    "BinkTransition",
)

LOOPS = (
    ("TrackMain", "TrackLoopStart", "TrackLoopEnd"),
    ("TrackPostRace", "PostRaceLoopStart", "PostRaceLoopEnd"),
    ("Loop1", "Loop1Start", "Loop1End"),
    ("Loop2", "Loop2Start", "Loop2End"),
    ("Loop3", "Loop3Start", "Loop3End"),
    ("Loop4", "Loop4Start", "Loop4End"),
    ("Loop5", "Loop5Start", "Loop5End"),
)

STATIONS = (
    (1, "Horizon Pulse"),
    (2, "Horizon Bass Arena"),
    (3, "Horizon Block Party"),
    (4, "Horizon XS"),
    (5, "Radio Eterna"),
    (6, "Hospital Records"),
    (7, "Future Classic"),
    (8, "Horizon Mixtape"),
    (9, "Horizon Wave"),
    (10, "Streamer Mode"),
)

MOCK_TRACKS = (
    ("HZ6_R4_MOCK_SLOT_01", "Mock Runway", "FH Radio Studio Dev", 960000),
    ("HZ6_R4_MOCK_SLOT_02", "Mock Switchback", "FH Radio Studio Dev", 1152000),
    ("HZ6_R4_MOCK_SLOT_03", "Mock Finish Line", "FH Radio Studio Dev", 1056000),
)


def mock_version_id(build_id: str) -> str:
    return f"steam-b{build_id}"


def default_root_for(build_id: str) -> Path:
    return REPO_ROOT / "test" / "fixtures" / "mock-game" / f"fh6-{mock_version_id(build_id)}"


def assert_safe_mock_root(path: Path) -> Path:
    resolved = path.resolve()
    fixture_root = (REPO_ROOT / "test" / "fixtures").resolve()
    try:
        resolved.relative_to(fixture_root)
    except ValueError:
        raise SystemExit(f"Refusing to write outside the repo test fixtures directory: {resolved}")
    if resolved == fixture_root:
        raise SystemExit(f"Refusing to replace the whole test fixtures directory: {resolved}")
    return resolved


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def marker_position(name: str, sample_length: int) -> int:
    positions = {
        "VeryStart": 0,
        "TrackStart": 0,
        "TrackDrop": 8 * 48000,
        "TrackLoopStart": 12 * 48000,
        "TrackLoopEnd": max(12 * 48000, sample_length - 6 * 48000),
        "PostDrop": max(0, sample_length - 12 * 48000),
        "PostRaceLoopStart": max(0, sample_length - 10 * 48000),
        "PostRaceLoopEnd": max(0, sample_length - 2 * 48000),
        "End": sample_length,
    }
    return positions.get(name, -1)


def add_sample(
    parent: ET.Element, sound_name: str, title: str, artist: str, sample_length: int
) -> None:
    sample = ET.SubElement(
        parent,
        "Sample",
        {
            "SoundName": sound_name,
            "SampleLength": str(sample_length),
            "SampleRate": "48000",
            "DisplayName": title,
            "Artist": artist,
            "IsXCloudModeSafe": "false",
        },
    )
    for name in MARKER_ORDER:
        ET.SubElement(
            sample, "Marker", {"Name": name, "Position": str(marker_position(name, sample_length))}
        )
    for loop_name, start, end in LOOPS:
        ET.SubElement(sample, "Loop", {"Name": loop_name, "StartMarker": start, "EndMarker": end})
    ET.SubElement(sample, "BPM", {"Value": "128", "Start": "-1"})


def build_radio_info(language: str) -> ET.ElementTree:
    root = ET.Element("RadioInfo", {"Language": language})
    stations = ET.SubElement(root, "RadioStations")
    for number, name in STATIONS:
        station = ET.SubElement(stations, "RadioStation", {"Number": str(number), "Name": name})
        banks = ET.SubElement(station, "Banks")
        track_bank = f"R{number}_Tracks_Disk"
        if number == 4:
            track_bank = "R4_Tracks_CU1"
        ET.SubElement(banks, "Bank", {"Name": track_bank})

        track_list = ET.SubElement(station, "SampleList", {"Type": "Track"})
        free_roam = ET.SubElement(station, "PlayList", {"Type": "FreeRoam"})
        event = ET.SubElement(station, "PlayList", {"Type": "Event"})
        if number == 4:
            for sound_name, title, artist, sample_length in MOCK_TRACKS:
                add_sample(track_list, sound_name, title, artist, sample_length)
                ET.SubElement(free_roam, "Entry", {"Name": sound_name})
                ET.SubElement(event, "Entry", {"Name": sound_name})
        else:
            sound_name = f"HZ6_R{number}_MOCK_REFERENCE"
            add_sample(
                track_list, sound_name, f"Mock R{number} Reference", "FH Radio Studio Dev", 900000
            )
            ET.SubElement(free_roam, "Entry", {"Name": sound_name})
            ET.SubElement(event, "Entry", {"Name": sound_name})
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    return tree


def write_radio_info_files(game_root: Path) -> None:
    audio_dir = game_root / "media" / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    for language in ("CN", "EN"):
        path = audio_dir / f"RadioInfo_{language}.xml"
        build_radio_info(language).write(
            path,
            encoding="utf-8",
            xml_declaration=True,
            short_empty_elements=True,
        )


def build_mock_fsb5(names: tuple[str, ...]) -> bytes:
    sample_headers = bytearray()
    for index, _name in enumerate(names):
        sample_count = MOCK_TRACKS[index][3]
        meta = (sample_count << 34) | (1 << 5) | (9 << 1)
        sample_headers.extend(struct.pack("<II", meta & 0xFFFFFFFF, (meta >> 32) & 0xFFFFFFFF))

    encoded_names = [name.encode("utf-8") + b"\x00" for name in names]
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
        len(names),
        len(sample_headers),
        len(name_table),
        0,
        1,
        0,
    )
    return bytes(header) + bytes(sample_headers) + name_table


def write_mock_bank(game_root: Path) -> None:
    bank_dir = game_root / "media" / "audio" / "FMODBanks"
    bank_dir.mkdir(parents=True, exist_ok=True)
    names = tuple(track[0] for track in MOCK_TRACKS)
    bank_bytes = b"MOCKFH6BANK\x00" + build_mock_fsb5(names)
    (bank_dir / "R4_Tracks_CU1.assets.bank").write_bytes(bank_bytes)


def write_string_table_zip(path: Path, language: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "mock_string_table.txt",
            f"FH Radio Studio mock StringTable for {language}\n",
        )


def write_string_tables(game_root: Path) -> None:
    string_dir = game_root / "media" / "Stripped" / "StringTables"
    for language in ("CHS", "EN", "JP"):
        write_string_table_zip(string_dir / f"{language}.zip", language)


def write_steam_manifest(root: Path, build_id: str) -> None:
    manifest = root / "steamapps" / f"appmanifest_{FH6_STEAM_APP_ID}.acf"
    write_text(
        manifest,
        "\n".join(
            [
                '"AppState"',
                "{",
                f'  "appid" "{FH6_STEAM_APP_ID}"',
                '  "Universe" "1"',
                '  "name" "Forza Horizon 6 Mock"',
                '  "StateFlags" "4"',
                '  "installdir" "ForzaHorizon6"',
                f'  "buildid" "{build_id}"',
                '  "LastUpdated" "1779235200"',
                "}",
                "",
            ]
        ),
    )


def write_profile(root: Path) -> None:
    write_text(root / PREFERRED_LANG_REL, "EN\n")


def write_readme(root: Path, game_root: Path, build_id: str) -> None:
    preferred = root / PREFERRED_LANG_REL
    write_text(
        root / "README.md",
        f"""# FH Radio Studio Mock Game

This is a small, disposable FH6-shaped directory for FH Radio Studio development tests.
Version: `fh6-{mock_version_id(build_id)}`.

It only contains files that the CLI/App reads or writes:

- `media/audio/RadioInfo_*.xml`
- `media/audio/FMODBanks/R4_Tracks_CU1.assets.bank`
- `media/Stripped/StringTables/*.zip`
- `profile/ForzaHorizon6/UserPreferredLang`

Use this as the game directory:

```powershell
uv run fh-radio-studio probe --game-dir "{game_root}"
uv run fh-radio-studio status --game-dir "{game_root}" --preferred-path "{preferred}" --json
uv run fh-radio-studio baseline plan --game-dir "{game_root}" --json
```

To reset the mock after a destructive test:

```powershell
python .\\tools\\test\\create_mock_game.py --reset
```
""",
    )


def write_metadata(root: Path, game_root: Path, build_id: str) -> None:
    metadata = {
        "schema_version": 1,
        "kind": "fh_radio_studio_mock_game",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "version_id": mock_version_id(build_id),
        "build_id": build_id,
        "game_dir": str(game_root),
        "preferred_lang_path": str(root / PREFERRED_LANG_REL),
        "radio": 4,
        "managed_files": [
            "media/audio/RadioInfo_CN.xml",
            "media/audio/RadioInfo_EN.xml",
            "media/audio/FMODBanks/R4_Tracks_CU1.assets.bank",
            "media/Stripped/StringTables/CHS.zip",
            "media/Stripped/StringTables/EN.zip",
            "media/Stripped/StringTables/JP.zip",
        ],
    }
    write_text(
        root / ".fh-radio-studio-mock.json",
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
    )


def create_mock(root: Path, reset: bool, build_id: str) -> tuple[Path, Path]:
    root = assert_safe_mock_root(root)
    if root.exists() and reset:
        shutil.rmtree(root)
    elif root.exists() and any(root.iterdir()):
        raise SystemExit(f"Mock root already exists. Pass --reset to recreate it: {root}")

    game_root = root / GAME_ROOT_REL
    write_steam_manifest(root, build_id)
    write_radio_info_files(game_root)
    write_mock_bank(game_root)
    write_string_tables(game_root)
    write_profile(root)
    write_readme(root, game_root, build_id)
    write_metadata(root, game_root, build_id)
    return root, game_root


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a small FH6-shaped mock game directory for development tests."
    )
    parser.add_argument(
        "--root",
        help="Output root under the repo test fixtures directory. Defaults to test/fixtures/mock-game/fh6-steam-b<build-id>.",
    )
    parser.add_argument(
        "--build-id",
        default=DEFAULT_BUILD_ID,
        help="Mock Steam build id used in the folder name and appmanifest.",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Delete and recreate the mock root if it already exists.",
    )
    args = parser.parse_args()

    build_id = str(args.build_id).strip() or DEFAULT_BUILD_ID
    root = Path(args.root).expanduser() if args.root else default_root_for(build_id)
    root, game_root = create_mock(root, args.reset, build_id)
    print(f"Mock root : {root}")
    print(f"Game dir  : {game_root}")
    print(f"Preferred : {root / PREFERRED_LANG_REL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
