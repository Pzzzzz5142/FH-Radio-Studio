"""Reconstruct a playlist plan by diffing the current game RadioInfo against the
trusted baseline, then resolving the changed tracks back to project source files.

This used to live in the Flutter UI (studio_state.dart). It now lives here so the
CLI stays the single source of truth for track metadata: the same RadioInfo
parsing (game.py) and metadata cache / title-artist resolution (metadata.py) that
build-package uses are reused, instead of maintaining a second metadata mechanism
in Dart. The UI just calls this command and reads the emitted playlist_plan.json.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional
from xml.etree import ElementTree as ET

from .common import PLAN_PREFIX, die, path_key
from .game import audio_dir_for, radio_info_files, resolve_game_dir
from .metadata import _load_cache_entries  # internal cache reader (path_key -> entry)
from .metadata import collect_audio_files, guess_track_metadata
from .package import (
    _baseline_audio_dir_from_manifest,
    normalize_playlist_type,
    radio_code_for_station,
)
from .project_json_guard import write_project_json
from .project_refs import ProjectRefError, resolve_project_ref, track_key_for_project_path

PLAYLIST_TYPES = ("FreeRoam", "Event")
_UNKNOWN_ARTIST = "Unknown Artist"


@dataclass(frozen=True)
class _DiffTrack:
    sound_name: str
    title: str
    artist: str

    @property
    def signature(self) -> str:
        return f"{self.sound_name.strip().lower()}|{_diff_meta_key(self.title, self.artist)}"


def _diff_meta_key(title: str, artist: str) -> str:
    return f"{artist.strip().lower()}|{title.strip().lower()}"


def is_ui_supported_radio(name: str) -> bool:
    return name.strip().lower() != "streamer mode"


def _radio_info_file_for_diff(
    audio_dir: Path,
    source_lang: str,
    target_lang: str,
) -> Optional[Path]:
    if not audio_dir.is_dir():
        return None
    seen: set[str] = set()
    for lang in (source_lang, target_lang, "EN", "GB", "CHS", "CN"):
        normalized = lang.strip().upper()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        candidate = audio_dir / f"RadioInfo_{normalized}.xml"
        if candidate.is_file():
            return candidate
    files = radio_info_files(audio_dir)
    return files[0] if files else None


def _safe_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _read_radio_info_playlists(xml_file: Path) -> Dict[str, Dict[str, List[_DiffTrack]]]:
    try:
        root = ET.parse(xml_file).getroot()
    except ET.ParseError:
        return {}
    except OSError:
        return {}

    out: Dict[str, Dict[str, List[_DiffTrack]]] = {}
    for station in root.iter("RadioStation"):
        number = _safe_int(station.get("Number"))
        name = (station.get("Name") or "").strip()
        if not is_ui_supported_radio(name):
            continue
        radio_code = radio_code_for_station(number if number is not None else 0, name)

        samples: Dict[str, _DiffTrack] = {}
        sample_order: List[_DiffTrack] = []
        for sample in station.iter("Sample"):
            sound_name = (sample.get("SoundName") or "").strip()
            if not sound_name:
                continue
            track = _DiffTrack(
                sound_name=sound_name,
                title=(sample.get("DisplayName") or "").strip() or sound_name,
                artist=(sample.get("Artist") or "").strip() or _UNKNOWN_ARTIST,
            )
            samples[sound_name] = track
            sample_order.append(track)

        lists: Dict[str, List[_DiffTrack]] = {}
        for playlist_type in PLAYLIST_TYPES:
            tracks: List[_DiffTrack] = []
            for playlist in station.findall("PlayList"):
                raw_type = playlist.get("Type") or "FreeRoam"
                if normalize_playlist_type(raw_type) != playlist_type:
                    continue
                for entry in playlist.findall("Entry"):
                    entry_name = (entry.get("Name") or "").strip()
                    track = samples.get(entry_name)
                    if track is not None:
                        tracks.append(track)
            lists[playlist_type] = tracks if tracks else sample_order
        out[radio_code] = lists
    return out


def _same_track_list(left: List[_DiffTrack], right: List[_DiffTrack]) -> bool:
    if len(left) != len(right):
        return False
    return all(a.signature == b.signature for a, b in zip(left, right))


def _project_sources_by_metadata(
    music_dirs: List[Path],
    metadata_cache: Optional[Path],
) -> Dict[str, str]:
    cache_by_key: Dict[str, tuple[str, str]] = {}
    if metadata_cache is not None and metadata_cache.is_file():
        project_dir = metadata_cache.parent.parent
        for entry in _load_cache_entries(metadata_cache).values():
            source_ref = entry.get("source_ref")
            title = entry.get("title")
            artist = entry.get("artist")
            # `source_ref` is authoritative; resolve it against the current
            # project root. The legacy absolute `source` is only a fallback for
            # pre-migration entries and goes stale once the project moves.
            source: Optional[str] = None
            if isinstance(source_ref, str):
                try:
                    source = str(resolve_project_ref(project_dir, source_ref))
                except ProjectRefError:
                    source = None
            if source is None and isinstance(entry.get("source"), str):
                source = entry.get("source")
            if isinstance(source, str) and isinstance(title, str) and isinstance(artist, str):
                cache_by_key[path_key(Path(source))] = (artist, title)

    out: Dict[str, str] = {}
    for file in collect_audio_files(music_dirs):
        cached = cache_by_key.get(path_key(file))
        if cached is not None:
            artist, title = cached
        else:
            artist, title = guess_track_metadata(file)
        out.setdefault(_diff_meta_key(title, artist), str(file.resolve()))
    return out


def reconstruct_playlist_plan(
    *,
    game_audio_dir: Path,
    baseline_audio_dir: Path,
    music_dirs: List[Path],
    metadata_cache: Optional[Path],
    source_lang: str,
    target_lang: str,
) -> List[Dict[str, object]]:
    game_xml = _radio_info_file_for_diff(game_audio_dir, source_lang, target_lang)
    baseline_xml = _radio_info_file_for_diff(baseline_audio_dir, source_lang, target_lang)
    if game_xml is None or baseline_xml is None:
        return []

    game = _read_radio_info_playlists(game_xml)
    baseline = _read_radio_info_playlists(baseline_xml)
    if not game or not baseline:
        return []

    sources_by_meta = _project_sources_by_metadata(music_dirs, metadata_cache)
    project_dir = (
        metadata_cache.parent.parent
        if metadata_cache is not None
        and metadata_cache.name == "track_metadata.json"
        and metadata_cache.parent.name == ".fh-radio-studio"
        else None
    )

    assignments: List[Dict[str, object]] = []
    for radio_code, game_lists in game.items():
        baseline_lists = baseline.get(radio_code, {})
        for playlist_type in PLAYLIST_TYPES:
            game_tracks = game_lists.get(playlist_type, [])
            baseline_tracks = baseline_lists.get(playlist_type, [])
            if _same_track_list(game_tracks, baseline_tracks):
                continue
            for index, track in enumerate(game_tracks):
                source = sources_by_meta.get(_diff_meta_key(track.title, track.artist))
                if not source:
                    continue
                track_key = (
                    track_key_for_project_path(project_dir, Path(source))
                    if project_dir is not None
                    else None
                )
                assignments.append(
                    {
                        **(
                            {"track_key": track_key}
                            if track_key is not None
                            else {"source": source}
                        ),
                        "radio_code": radio_code,
                        "playlist_type": playlist_type,
                        "slot": index + 1,
                    }
                )
    return assignments


def cmd_reconstruct_plan(args: argparse.Namespace) -> int:
    game_dir = resolve_game_dir(args.game_dir)
    game_audio_dir = audio_dir_for(game_dir)

    if not args.baseline_manifest:
        die("--baseline-manifest is required to reconstruct a playlist plan.")
    baseline_audio_dir = _baseline_audio_dir_from_manifest(args.baseline_manifest)
    if baseline_audio_dir is None:
        die(f"Baseline audio directory not found for manifest: {args.baseline_manifest}")

    music_dirs = [Path(value).expanduser() for value in (args.music_dir or [])]
    metadata_cache = Path(args.metadata_cache).expanduser() if args.metadata_cache else None

    assignments = reconstruct_playlist_plan(
        game_audio_dir=game_audio_dir,
        baseline_audio_dir=baseline_audio_dir,
        music_dirs=music_dirs,
        metadata_cache=metadata_cache,
        source_lang=args.source or "",
        target_lang=args.target or "",
    )

    payload: Dict[str, object] = {
        "schema_version": 2,
        "assignments": assignments,
        "builtin_targets": [],
    }

    if args.out == "-":
        # Emit the plan on stdout as a single marker-prefixed compact JSON line
        # so the UI can read it without a file; keep the human summary on stderr.
        print(f"{PLAN_PREFIX}{json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}")
        print(f"Assignments  : {len(assignments)}", file=sys.stderr)
        return 0

    out_path = Path(args.out).expanduser()
    write_project_json(out_path, payload)

    print(f"Plan written : {out_path}")
    print(f"Assignments  : {len(assignments)}")
    return 0
