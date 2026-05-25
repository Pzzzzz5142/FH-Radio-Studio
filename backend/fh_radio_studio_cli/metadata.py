from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional

from .common import die, path_key, sf, write_json

UNKNOWN_ARTIST = "Unknown Artist"
TRACK_METADATA_CACHE_NAME = "track_metadata.json"
AUDIO_SUFFIXES = {".wav", ".flac", ".ogg", ".aiff", ".aif", ".mp3", ".m4a", ".aac"}
LOUDNESS_ANALYSIS_CACHE_KEY = "loudness_analysis"
LOUDNESS_CACHE_META_KEYS = {"cached_at", "source_size", "source_mtime_ms"}
_IMPORT_COMPLETE_TAG = "FH_RADIO_STUDIO_IMPORT_COMPLETE"
_IMPORT_COMPLETE_VALUE = "1"
_MP4_IMPORT_COMPLETE_KEY = "----:com.fh-radio-studio:import-complete"


@dataclass(frozen=True)
class TrackMetadata:
    artist: str
    title: str
    from_tags: bool = False
    duration_sec: Optional[float] = None
    sample_rate: Optional[int] = None
    channels: Optional[int] = None
    samples: Optional[int] = None


@dataclass(frozen=True)
class EmbeddedCover:
    data: bytes
    mime: str


def fallback_track_metadata(path: Path) -> TrackMetadata:
    stem = re.sub(r"^\s*\d+\s*[-_. ]+\s*", "", path.stem).strip()
    parts = [part.strip() for part in re.split(r"\s+-\s+", stem, maxsplit=1)]
    if len(parts) == 2 and parts[0] and parts[1]:
        return TrackMetadata(artist=parts[0], title=parts[1], from_tags=False)
    return TrackMetadata(artist=UNKNOWN_ARTIST, title=stem or path.stem, from_tags=False)


def guess_track_metadata(path: Path) -> tuple[str, str]:
    metadata = read_track_metadata(path)
    return metadata.artist, metadata.title


def read_track_metadata(path: Path) -> TrackMetadata:
    fallback = fallback_track_metadata(path)
    tags = _read_audio_tags(path)
    info = _read_audio_info(path)
    tag_title = _clean_tag(tags.get("title"))
    tag_artist = (
        _clean_tag(tags.get("artist"))
        or _clean_tag(tags.get("album_artist"))
        or _clean_tag(tags.get("albumartist"))
    )
    return TrackMetadata(
        artist=tag_artist or fallback.artist,
        title=tag_title or fallback.title,
        from_tags=tag_artist is not None or tag_title is not None,
        duration_sec=info.get("duration_sec"),
        sample_rate=info.get("sample_rate"),
        channels=info.get("channels"),
        samples=info.get("samples"),
    )


def write_track_metadata_tags(
    path: Path,
    *,
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    cover_image: Optional[Path] = None,
) -> bool:
    title = _clean_tag(title)
    artist = _clean_tag(artist)
    album = _clean_tag(album)
    cover = _read_cover_image_file(cover_image)
    if not title and not artist and not album and cover is None:
        return False
    suffix = path.suffix.lower()
    if suffix in {".wav", ".aif", ".aiff", ".mp3"}:
        return _write_id3_container_tags(
            path,
            title=title,
            artist=artist,
            album=album,
            cover=cover,
        )
    if suffix == ".flac":
        return _write_flac_container_tags(
            path,
            title=title,
            artist=artist,
            album=album,
            cover=cover,
        )
    if suffix in {".m4a", ".mp4", ".aac"}:
        return _write_mp4_container_tags(
            path,
            title=title,
            artist=artist,
            album=album,
            cover=cover,
        )
    if suffix == ".ogg":
        return _write_vorbis_comment_tags(
            path,
            title=title,
            artist=artist,
            album=album,
            cover=cover,
        )
    return _write_easy_tags(path, title=title, artist=artist, album=album)


def write_import_completion_marker(path: Path) -> bool:
    suffix = path.suffix.lower()
    if suffix in {".wav", ".aif", ".aiff", ".mp3"}:
        return _write_id3_import_completion_marker(path)
    if suffix == ".flac":
        return _write_flac_import_completion_marker(path)
    if suffix in {".m4a", ".mp4", ".aac"}:
        return _write_mp4_import_completion_marker(path)
    if suffix == ".ogg":
        return _write_vorbis_import_completion_marker(path)
    return False


def has_import_completion_marker(path: Path) -> bool:
    suffix = path.suffix.lower()
    if suffix in {".wav", ".aif", ".aiff", ".mp3"}:
        return _has_id3_import_completion_marker(path)
    if suffix == ".flac":
        return _has_flac_import_completion_marker(path)
    if suffix in {".m4a", ".mp4", ".aac"}:
        return _has_mp4_import_completion_marker(path)
    if suffix == ".ogg":
        return _has_vorbis_import_completion_marker(path)
    return False


def metadata_cache_path(project_dir: Path) -> Path:
    return project_dir / ".fh-radio-studio" / TRACK_METADATA_CACHE_NAME


def infer_metadata_cache_path_from_timing_manifest(
    timing_manifest: Optional[str],
) -> Optional[Path]:
    if not timing_manifest:
        return None
    manifest_path = Path(timing_manifest).expanduser()
    if manifest_path.parent.name.lower() != "analysis":
        return None
    return metadata_cache_path(manifest_path.parent.parent)


def collect_audio_files(inputs: Iterable[Path]) -> List[Path]:
    files: List[Path] = []
    seen: set[str] = set()
    for raw in inputs:
        path = raw.expanduser()
        if path.is_file():
            if _is_audio_path(path) and path_key(path) not in seen:
                seen.add(path_key(path))
                files.append(path.resolve())
            continue
        if not path.is_dir():
            continue
        children = sorted(
            (item for item in path.iterdir() if item.is_file() and _is_audio_path(item)),
            key=lambda item: str(item).casefold(),
        )
        for child in children:
            key = path_key(child)
            if key in seen:
                continue
            seen.add(key)
            files.append(child.resolve())
    return files


def cmd_scan_metadata(args: argparse.Namespace) -> int:
    project_dir = Path(args.project_dir).expanduser().resolve()
    if not project_dir:
        die("--project-dir is required")

    inputs = [Path(value) for value in args.inputs]
    if args.all_sources or not inputs:
        inputs.append(project_dir / "sources")
        inputs.append(project_dir / "siren")
    files = collect_audio_files(inputs)

    cache_path = metadata_cache_path(project_dir)
    artwork_dir = cache_path.parent / "artwork"
    entries = _load_cache_entries(cache_path)
    updated = 0
    for file in files:
        key = path_key(file)
        entries[key] = build_track_metadata_cache_entry(
            file,
            existing=entries.get(key),
            artwork_dir=artwork_dir,
        )
        updated += 1

    payload: Dict[str, object] = {
        "schema_version": 1,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "tracks": sorted(
            entries.values(),
            key=lambda item: str(item.get("source", "")).casefold(),
        ),
    }
    write_json(cache_path, payload)

    summary = {
        "cache": str(cache_path),
        "scanned": len(files),
        "updated": updated,
        "total": len(entries),
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False))
    else:
        print(f"Metadata cache: {cache_path}")
        print(f"Scanned       : {len(files)}")
        print(f"Cached tracks : {len(entries)}")
    return 0


def upsert_track_metadata_cache_entry(
    cache_path: Path,
    path: Path,
    *,
    loudness_analysis: Optional[Dict[str, object]] = None,
) -> None:
    entries = _load_cache_entries(cache_path)
    key = path_key(path)
    entries[key] = build_track_metadata_cache_entry(
        path,
        existing=entries.get(key),
        loudness_analysis=loudness_analysis,
        artwork_dir=cache_path.parent / "artwork",
    )
    _write_cache_entries(cache_path, entries)


def build_track_metadata_cache_entry(
    path: Path,
    *,
    existing: Optional[Dict[str, object]] = None,
    loudness_analysis: Optional[Dict[str, object]] = None,
    artwork_dir: Optional[Path] = None,
) -> Dict[str, object]:
    metadata = read_track_metadata(path)
    stat = path.stat()
    entry: Dict[str, object] = {
        "source": str(path.resolve()),
        "path_key": path_key(path),
        "artist": metadata.artist,
        "title": metadata.title,
        "from_tags": metadata.from_tags,
        "duration_sec": metadata.duration_sec,
        "sample_rate": metadata.sample_rate,
        "channels": metadata.channels,
        "samples": metadata.samples,
        "size": stat.st_size,
        "mtime_ms": int(stat.st_mtime * 1000),
    }
    if artwork_dir is not None:
        cover = extract_track_cover_art(path, artwork_dir)
        if cover is not None:
            cover_path, cover_mime, cover_size = cover
            entry["cover_art_path"] = str(cover_path)
            entry["cover_art_mime"] = cover_mime
            entry["cover_art_size"] = cover_size
    if loudness_analysis is not None:
        entry[LOUDNESS_ANALYSIS_CACHE_KEY] = _loudness_cache_payload(loudness_analysis, stat)
    elif existing:
        preserved = _preserved_loudness_payload(existing, stat)
        if preserved is not None:
            entry[LOUDNESS_ANALYSIS_CACHE_KEY] = preserved
    return entry


def extract_track_cover_art(path: Path, artwork_dir: Path) -> Optional[tuple[Path, str, int]]:
    cover = _read_embedded_cover(path)
    if cover is None:
        return None
    digest = hashlib.sha256()
    digest.update(path_key(path).encode("utf-8", errors="replace"))
    digest.update(b"\0")
    digest.update(cover.mime.encode("ascii", errors="replace"))
    digest.update(b"\0")
    digest.update(cover.data)
    filename = f"{digest.hexdigest()[:24]}.{_cover_extension(cover.mime)}"
    target = artwork_dir / filename
    try:
        artwork_dir.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != cover.data:
            target.write_bytes(cover.data)
    except OSError:
        return None
    return target.resolve(), cover.mime, len(cover.data)


def cached_loudness_analysis_for_path(
    cache_path: Optional[Path],
    path: Path,
    *,
    algorithm_version: str,
) -> Optional[Dict[str, object]]:
    if cache_path is None or not cache_path.exists():
        return None
    entries = _load_cache_entries(cache_path)
    entry = entries.get(path_key(path))
    if not entry:
        return None
    try:
        stat = path.stat()
    except OSError:
        return None
    payload = _preserved_loudness_payload(
        entry,
        stat,
        algorithm_version=algorithm_version,
    )
    if payload is None or payload.get("status") != "ok":
        return None
    analysis = {key: value for key, value in payload.items() if key not in LOUDNESS_CACHE_META_KEYS}
    analysis["source"] = str(path.resolve())
    return analysis


def _load_cache_entries(cache_path: Path) -> Dict[str, Dict[str, object]]:
    if not cache_path.exists():
        return {}
    try:
        decoded = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(decoded, dict):
        return {}
    tracks = decoded.get("tracks")
    if not isinstance(tracks, list):
        return {}
    out: Dict[str, Dict[str, object]] = {}
    for item in tracks:
        if not isinstance(item, dict):
            continue
        source = item.get("source")
        key = item.get("path_key")
        if isinstance(source, str) and source:
            cache_key = key if isinstance(key, str) and key else path_key(Path(source))
            out[cache_key] = dict(item)
    return out


def _write_cache_entries(cache_path: Path, entries: Dict[str, Dict[str, object]]) -> None:
    payload: Dict[str, object] = {
        "schema_version": 1,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "tracks": sorted(
            entries.values(),
            key=lambda item: str(item.get("source", "")).casefold(),
        ),
    }
    write_json(cache_path, payload)


def _loudness_cache_payload(analysis: Dict[str, object], stat: os.stat_result) -> Dict[str, object]:
    payload = dict(analysis)
    payload["source_size"] = stat.st_size
    payload["source_mtime_ms"] = int(stat.st_mtime * 1000)
    payload["cached_at"] = datetime.now(timezone.utc).isoformat()
    return payload


def _preserved_loudness_payload(
    entry: Dict[str, object],
    stat: os.stat_result,
    *,
    algorithm_version: Optional[str] = None,
) -> Optional[Dict[str, object]]:
    payload = entry.get(LOUDNESS_ANALYSIS_CACHE_KEY)
    if not isinstance(payload, dict):
        return None
    if algorithm_version and payload.get("algorithm_version") != algorithm_version:
        return None
    if payload.get("source_size") != stat.st_size:
        return None
    try:
        cached_mtime = int(payload.get("source_mtime_ms"))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if cached_mtime != int(stat.st_mtime * 1000):
        return None
    return dict(payload)


def _read_audio_info(path: Path) -> Dict[str, object]:
    try:
        info = sf.info(str(path))
    except Exception:
        return _read_mutagen_audio_info(path)
    sample_rate = int(info.samplerate or 0)
    samples = int(info.frames or 0)
    duration = samples / sample_rate if sample_rate > 0 and samples > 0 else None
    return {
        "duration_sec": round(duration, 3) if duration is not None else None,
        "sample_rate": sample_rate or None,
        "channels": int(info.channels or 0) or None,
        "samples": samples or None,
    }


def _read_audio_tags(path: Path) -> Dict[str, str]:
    tags: Dict[str, str] = {}
    for key, value in _read_mutagen_tags(path).items():
        cleaned = _clean_tag(value)
        if cleaned:
            tags.setdefault(key, cleaned)

    try:
        data = path.read_bytes()
    except OSError:
        return tags

    for reader in (
        _read_id3v2_tags,
        _read_flac_tags,
        _read_ogg_tags,
        _read_wav_info_tags,
        _read_wav_id3_tags,
        _read_aiff_tags,
        _read_mp4_tags,
        _read_id3v1_tags,
    ):
        try:
            for key, value in reader(data).items():
                cleaned = _clean_tag(value)
                if cleaned:
                    tags.setdefault(key, cleaned)
        except (IndexError, UnicodeDecodeError, ValueError, OverflowError):
            continue
    return tags


def _read_mutagen_audio_info(path: Path) -> Dict[str, object]:
    try:
        from mutagen import File as MutagenFile

        audio = MutagenFile(str(path))
    except Exception:
        return {}
    info = getattr(audio, "info", None)
    if info is None:
        return {}
    duration = _positive_float(getattr(info, "length", None))
    sample_rate = _positive_int(getattr(info, "sample_rate", None))
    channels = _positive_int(getattr(info, "channels", None))
    samples = (
        round(duration * sample_rate) if duration is not None and sample_rate is not None else None
    )
    return {
        "duration_sec": round(duration, 3) if duration is not None else None,
        "sample_rate": sample_rate,
        "channels": channels,
        "samples": samples,
    }


def _write_id3_container_tags(
    path: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover: Optional[EmbeddedCover],
) -> bool:
    try:
        if path.suffix.lower() == ".wav":
            from mutagen.wave import WAVE

            audio = WAVE(str(path))
        elif path.suffix.lower() in {".aif", ".aiff"}:
            from mutagen.aiff import AIFF

            audio = AIFF(str(path))
        else:
            from mutagen.mp3 import MP3

            audio = MP3(str(path))
        from mutagen.id3 import APIC, TALB, TIT2, TPE1, TPE2

        if audio.tags is None:
            audio.add_tags()
        if title:
            audio.tags.setall("TIT2", [TIT2(encoding=3, text=[title])])
        if artist:
            audio.tags.setall("TPE1", [TPE1(encoding=3, text=[artist])])
            audio.tags.setall("TPE2", [TPE2(encoding=3, text=[artist])])
        if album:
            audio.tags.setall("TALB", [TALB(encoding=3, text=[album])])
        if cover is not None:
            audio.tags.delall("APIC")
            audio.tags.add(
                APIC(
                    encoding=3,
                    mime=cover.mime,
                    type=3,
                    desc="Cover",
                    data=cover.data,
                )
            )
        audio.save()
        return True
    except Exception:
        return False


def _write_id3_import_completion_marker(path: Path) -> bool:
    try:
        if path.suffix.lower() == ".wav":
            from mutagen.wave import WAVE

            audio = WAVE(str(path))
        elif path.suffix.lower() in {".aif", ".aiff"}:
            from mutagen.aiff import AIFF

            audio = AIFF(str(path))
        else:
            from mutagen.mp3 import MP3

            audio = MP3(str(path))
        from mutagen.id3 import TXXX

        if audio.tags is None:
            audio.add_tags()
        audio.tags.setall(
            "TXXX",
            [
                frame
                for frame in audio.tags.getall("TXXX")
                if getattr(frame, "desc", "") != _IMPORT_COMPLETE_TAG
            ]
            + [TXXX(encoding=3, desc=_IMPORT_COMPLETE_TAG, text=[_IMPORT_COMPLETE_VALUE])],
        )
        audio.save()
        return True
    except Exception:
        return False


def _has_id3_import_completion_marker(path: Path) -> bool:
    try:
        if path.suffix.lower() == ".wav":
            from mutagen.wave import WAVE

            audio = WAVE(str(path))
        elif path.suffix.lower() in {".aif", ".aiff"}:
            from mutagen.aiff import AIFF

            audio = AIFF(str(path))
        else:
            from mutagen.mp3 import MP3

            audio = MP3(str(path))
    except Exception:
        return False
    tags = getattr(audio, "tags", None)
    if tags is None:
        return False
    for frame in tags.getall("TXXX"):
        if getattr(frame, "desc", "") != _IMPORT_COMPLETE_TAG:
            continue
        if _IMPORT_COMPLETE_VALUE in _flatten_tag_value(getattr(frame, "text", None)):
            return True
    return False


def _write_flac_container_tags(
    path: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover: Optional[EmbeddedCover],
) -> bool:
    try:
        from mutagen.flac import FLAC, Picture

        audio = FLAC(str(path))
        if title:
            audio["title"] = [title]
        if artist:
            audio["artist"] = [artist]
            audio["albumartist"] = [artist]
        if album:
            audio["album"] = [album]
        if cover is not None:
            picture = Picture()
            picture.type = 3
            picture.mime = cover.mime
            picture.desc = "Cover"
            picture.data = cover.data
            audio.clear_pictures()
            audio.add_picture(picture)
        audio.save()
        return True
    except Exception:
        return False


def _write_flac_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen.flac import FLAC

        audio = FLAC(str(path))
        audio[_IMPORT_COMPLETE_TAG] = [_IMPORT_COMPLETE_VALUE]
        audio.save()
        return True
    except Exception:
        return False


def _has_flac_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen.flac import FLAC

        audio = FLAC(str(path))
    except Exception:
        return False
    return _has_comment_import_completion_marker(audio)


def _write_mp4_container_tags(
    path: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover: Optional[EmbeddedCover],
) -> bool:
    try:
        from mutagen.mp4 import MP4, MP4Cover

        audio = MP4(str(path))
        if title:
            audio["\xa9nam"] = [title]
        if artist:
            audio["\xa9ART"] = [artist]
            audio["aART"] = [artist]
        if album:
            audio["\xa9alb"] = [album]
        if cover is not None:
            image_format = (
                MP4Cover.FORMAT_PNG if cover.mime == "image/png" else MP4Cover.FORMAT_JPEG
            )
            audio["covr"] = [MP4Cover(cover.data, imageformat=image_format)]
        audio.save()
        return True
    except Exception:
        return False


def _write_mp4_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen.mp4 import MP4

        audio = MP4(str(path))
        audio[_MP4_IMPORT_COMPLETE_KEY] = [_IMPORT_COMPLETE_VALUE.encode("utf-8")]
        audio.save()
        return True
    except Exception:
        return False


def _has_mp4_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen.mp4 import MP4

        audio = MP4(str(path))
    except Exception:
        return False
    values = audio.get(_MP4_IMPORT_COMPLETE_KEY, [])
    return _IMPORT_COMPLETE_VALUE in _flatten_tag_value(values)


def _write_vorbis_comment_tags(
    path: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover: Optional[EmbeddedCover],
) -> bool:
    try:
        from mutagen import File as MutagenFile
        from mutagen.flac import Picture

        audio = MutagenFile(str(path))
        if audio is None:
            return False
        if audio.tags is None:
            audio.add_tags()
        if title:
            audio["title"] = [title]
        if artist:
            audio["artist"] = [artist]
            audio["albumartist"] = [artist]
        if album:
            audio["album"] = [album]
        if cover is not None:
            picture = Picture()
            picture.type = 3
            picture.mime = cover.mime
            picture.desc = "Cover"
            picture.data = cover.data
            audio["metadata_block_picture"] = [base64.b64encode(picture.write()).decode("ascii")]
        audio.save()
        return True
    except Exception:
        return False


def _write_vorbis_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen import File as MutagenFile

        audio = MutagenFile(str(path))
        if audio is None:
            return False
        if audio.tags is None:
            audio.add_tags()
        audio[_IMPORT_COMPLETE_TAG] = [_IMPORT_COMPLETE_VALUE]
        audio.save()
        return True
    except Exception:
        return False


def _has_vorbis_import_completion_marker(path: Path) -> bool:
    try:
        from mutagen import File as MutagenFile

        audio = MutagenFile(str(path))
    except Exception:
        return False
    if audio is None:
        return False
    return _has_comment_import_completion_marker(audio)


def _write_easy_tags(
    path: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
) -> bool:
    try:
        from mutagen import File as MutagenFile

        audio = MutagenFile(str(path), easy=True)
        if audio is None:
            return False
        if audio.tags is None:
            audio.add_tags()
        if title:
            audio["title"] = [title]
        if artist:
            audio["artist"] = [artist]
            audio["albumartist"] = [artist]
        if album:
            audio["album"] = [album]
        audio.save()
        return True
    except Exception:
        return False


def _read_mutagen_tags(path: Path) -> Dict[str, str]:
    try:
        from mutagen import File as MutagenFile
    except Exception:
        return {}

    out: Dict[str, str] = {}
    for easy in (True, False):
        try:
            audio = MutagenFile(str(path), easy=easy)
        except Exception:
            continue
        tags = getattr(audio, "tags", None)
        if not tags:
            continue
        _collect_mutagen_tags(tags, out)
    return out


def _read_embedded_cover(path: Path) -> Optional[EmbeddedCover]:
    try:
        from mutagen import File as MutagenFile
    except Exception:
        return None

    try:
        audio = MutagenFile(str(path))
    except Exception:
        return None
    if audio is None:
        return None

    for picture in getattr(audio, "pictures", []) or []:
        data = getattr(picture, "data", None)
        if isinstance(data, bytes) and data:
            return EmbeddedCover(
                data=data,
                mime=_cover_mime_from_bytes(
                    data,
                    _clean_optional_text(getattr(picture, "mime", None)),
                ),
            )

    tags = getattr(audio, "tags", None)
    if tags:
        getall = getattr(tags, "getall", None)
        if callable(getall):
            for picture in getall("APIC"):
                data = getattr(picture, "data", None)
                if isinstance(data, bytes) and data:
                    return EmbeddedCover(
                        data=data,
                        mime=_cover_mime_from_bytes(
                            data,
                            _clean_optional_text(getattr(picture, "mime", None)),
                        ),
                    )
        if hasattr(tags, "get"):
            covr = tags.get("covr")
            if isinstance(covr, (list, tuple)):
                for item in covr:
                    try:
                        data = bytes(item)
                    except (TypeError, ValueError):
                        continue
                    if not data:
                        continue
                    return EmbeddedCover(data=data, mime=_mp4_cover_mime(item, data))
            metadata_blocks = tags.get("metadata_block_picture")
            if isinstance(metadata_blocks, str):
                metadata_blocks = [metadata_blocks]
            if isinstance(metadata_blocks, (list, tuple)):
                cover = _cover_from_metadata_block_picture(metadata_blocks)
                if cover is not None:
                    return cover
    return None


def _cover_from_metadata_block_picture(values: Iterable[object]) -> Optional[EmbeddedCover]:
    try:
        from mutagen.flac import Picture
    except Exception:
        return None
    for value in values:
        try:
            raw = base64.b64decode(str(value), validate=False)
            picture = Picture(raw)
        except Exception:
            continue
        if picture.data:
            return EmbeddedCover(
                data=picture.data,
                mime=_cover_mime_from_bytes(picture.data, _clean_optional_text(picture.mime)),
            )
    return None


def _read_cover_image_file(path: Optional[Path]) -> Optional[EmbeddedCover]:
    if path is None:
        return None
    try:
        data = Path(path).expanduser().read_bytes()
    except OSError:
        return None
    if not data:
        return None
    return EmbeddedCover(
        data=data,
        mime=_cover_mime_from_bytes(data, _mime_from_extension(Path(path).suffix)),
    )


def _mp4_cover_mime(item: object, data: bytes) -> str:
    try:
        from mutagen.mp4 import MP4Cover

        image_format = getattr(item, "imageformat", None)
        if image_format == MP4Cover.FORMAT_PNG:
            return "image/png"
        if image_format == MP4Cover.FORMAT_JPEG:
            return "image/jpeg"
    except Exception:
        pass
    return _cover_mime_from_bytes(data, None)


def _cover_mime_from_bytes(data: bytes, fallback: Optional[str]) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "image/gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    if fallback and fallback.startswith("image/"):
        return fallback
    return "image/jpeg"


def _mime_from_extension(suffix: str) -> Optional[str]:
    normalized = suffix.lower().lstrip(".")
    if normalized in {"jpg", "jpeg"}:
        return "image/jpeg"
    if normalized == "png":
        return "image/png"
    if normalized == "gif":
        return "image/gif"
    if normalized == "webp":
        return "image/webp"
    return None


def _cover_extension(mime: str) -> str:
    return {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/webp": "webp",
    }.get(mime, "jpg")


def _clean_optional_text(value: object) -> Optional[str]:
    return _clean_tag(str(value)) if value is not None else None


def _has_comment_import_completion_marker(audio: object) -> bool:
    tags = getattr(audio, "tags", None) or audio
    items = tags.items() if hasattr(tags, "items") else []
    expected_key = _normalize_tag_key(_IMPORT_COMPLETE_TAG)
    for raw_key, raw_value in items:
        if _normalize_tag_key(str(raw_key)) != expected_key:
            continue
        if _IMPORT_COMPLETE_VALUE in _flatten_tag_value(raw_value):
            return True
    return False


def _collect_mutagen_tags(tags: object, out: Dict[str, str]) -> None:
    items = tags.items() if hasattr(tags, "items") else []
    for raw_key, raw_value in items:
        key = _mutagen_key_target(raw_key)
        if key is None:
            continue
        value = _tag_value_to_text(raw_value)
        if value:
            out.setdefault(key, value)


def _mutagen_key_target(key: object) -> Optional[str]:
    raw = str(key).strip()
    normalized = _normalize_tag_key(raw)
    if normalized in {"title", "tit2", "tt2", "©nam", "wm/title", "name"} or normalized.endswith(
        ":title"
    ):
        return "title"
    if normalized in {
        "albumartist",
        "album_artist",
        "albumartists",
        "album_artists",
        "aart",
        "tpe2",
        "tp2",
        "wm/albumartist",
        "wm/album_artist",
    } or normalized.endswith((":albumartist", ":album_artist", ":album_artists")):
        return "albumartist"
    if normalized in {
        "artist",
        "artists",
        "performer",
        "author",
        "©art",
        "tpe1",
        "tp1",
        "wm/artist",
        "wm/author",
    } or normalized.endswith((":artist", ":artists", ":performer")):
        return "artist"
    return None


def _normalize_tag_key(key: str) -> str:
    return key.strip().lower().replace(" ", "_").replace("-", "_")


def _tag_value_to_text(value: object) -> Optional[str]:
    parts = []
    for part in _flatten_tag_value(value):
        cleaned = _clean_tag(part)
        if cleaned and cleaned not in parts:
            parts.append(cleaned)
    return "; ".join(parts) if parts else None


def _flatten_tag_value(value: object) -> List[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, bytes):
        text = _decode_loose_text(value)
        return [text] if text else []
    if isinstance(value, (list, tuple)):
        out: List[str] = []
        for item in value:
            out.extend(_flatten_tag_value(item))
        return out
    text = getattr(value, "text", None)
    if text is not None:
        return _flatten_tag_value(text)
    raw_value = getattr(value, "value", None)
    if raw_value is not None and raw_value is not value:
        return _flatten_tag_value(raw_value)
    return [str(value)]


def _read_id3v2_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 10 or data[:3] != b"ID3":
        return {}
    version = data[3]
    flags = data[5]
    tag_size = _syncsafe32(data, 6)
    end = min(10 + tag_size, len(data))
    offset = 10
    if flags & 0x40 and offset + 4 <= end:
        if version == 4:
            ext_size = _syncsafe32(data, offset)
        else:
            ext_size = _be32(data, offset)
        offset += max(4, ext_size)

    out: Dict[str, str] = {}
    while offset < end:
        if version == 2:
            if offset + 6 > end:
                break
            frame_id = data[offset : offset + 3].decode("latin1")
            size = int.from_bytes(data[offset + 3 : offset + 6], "big")
            header_size = 6
        else:
            if offset + 10 > end:
                break
            frame_id = data[offset : offset + 4].decode("latin1")
            size = _syncsafe32(data, offset + 4) if version == 4 else _be32(data, offset + 4)
            header_size = 10
        if not frame_id.strip("\x00 ") or size <= 0:
            break
        body_start = offset + header_size
        body_end = min(body_start + size, end)
        body = data[body_start:body_end]
        key: Optional[str]
        value: Optional[str]
        if frame_id in {"TXXX", "TXX"}:
            description, value = _decode_id3_user_text(body)
            key = _id3_user_text_target(description)
        else:
            value = _decode_id3_text(body)
            key = {
                "TIT2": "title",
                "TT2": "title",
                "TPE1": "artist",
                "TP1": "artist",
                "TPE2": "albumartist",
                "TP2": "albumartist",
            }.get(frame_id)
        if key and value:
            out[key] = value
        offset = body_end
    return out


def _read_id3v1_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 128 or data[-128:-125] != b"TAG":
        return {}
    title = _clean_tag(data[-125:-95].decode("latin1", errors="replace"))
    artist = _clean_tag(data[-95:-65].decode("latin1", errors="replace"))
    return {
        **({"title": title} if title else {}),
        **({"artist": artist} if artist else {}),
    }


def _read_flac_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 8 or data[:4] != b"fLaC":
        return {}
    offset = 4
    while offset + 4 <= len(data):
        header = data[offset]
        last = bool(header & 0x80)
        block_type = header & 0x7F
        length = int.from_bytes(data[offset + 1 : offset + 4], "big")
        offset += 4
        if offset + length > len(data):
            break
        if block_type == 4:
            return _read_vorbis_comment_block(data[offset : offset + length])
        offset += length
        if last:
            break
    return {}


def _read_ogg_tags(data: bytes) -> Dict[str, str]:
    vorbis = data.find(b"\x03vorbis")
    if vorbis >= 0:
        return _read_vorbis_comment_block(data[vorbis + 7 :])
    opus = data.find(b"OpusTags")
    if opus >= 0:
        return _read_vorbis_comment_block(data[opus + 8 :])
    return {}


def _read_vorbis_comment_block(data: bytes) -> Dict[str, str]:
    if len(data) < 8:
        return {}
    vendor_length = _le32(data, 0)
    offset = 4 + vendor_length
    if offset + 4 > len(data):
        return {}
    count = _le32(data, offset)
    offset += 4
    out: Dict[str, str] = {}
    for _ in range(count):
        if offset + 4 > len(data):
            break
        length = _le32(data, offset)
        offset += 4
        if offset + length > len(data):
            break
        entry = data[offset : offset + length].decode("utf-8", errors="replace")
        offset += length
        if "=" not in entry:
            continue
        key, value = entry.split("=", 1)
        normalized = key.strip().lower().replace(" ", "_")
        if normalized in {"title", "artist", "albumartist", "album_artist"}:
            cleaned = _clean_tag(value)
            if cleaned:
                out.setdefault(normalized, cleaned)
    return out


def _read_wav_info_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return {}
    offset = 12
    out: Dict[str, str] = {}
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        size = _le32(data, offset + 4)
        data_start = offset + 8
        data_end = min(data_start + size, len(data))
        if (
            chunk_id == b"LIST"
            and data_end - data_start >= 4
            and data[data_start : data_start + 4] == b"INFO"
        ):
            info_offset = data_start + 4
            while info_offset + 8 <= data_end:
                info_id = data[info_offset : info_offset + 4]
                info_size = _le32(data, info_offset + 4)
                value_start = info_offset + 8
                value_end = min(value_start + info_size, data_end)
                value = _decode_loose_text(data[value_start:value_end])
                key = {b"INAM": "title", b"IART": "artist"}.get(info_id)
                if key and value:
                    out[key] = value
                info_offset = value_end + (info_size % 2)
        offset = data_end + (size % 2)
    return out


def _read_wav_id3_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return {}
    offset = 12
    out: Dict[str, str] = {}
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        size = _le32(data, offset + 4)
        data_start = offset + 8
        data_end = min(data_start + size, len(data))
        if chunk_id.lower() == b"id3 ":
            out.update(_read_id3v2_tags(data[data_start:data_end]))
        offset = data_end + (size % 2)
    return out


def _read_aiff_tags(data: bytes) -> Dict[str, str]:
    if len(data) < 12 or data[:4] != b"FORM" or data[8:12] not in {b"AIFF", b"AIFC"}:
        return {}
    offset = 12
    out: Dict[str, str] = {}
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        size = _be32(data, offset + 4)
        data_start = offset + 8
        data_end = min(data_start + size, len(data))
        if chunk_id == b"NAME":
            value = _decode_loose_text(data[data_start:data_end])
            if value:
                out["title"] = value
        elif chunk_id == b"AUTH":
            value = _decode_loose_text(data[data_start:data_end])
            if value:
                out["artist"] = value
        elif chunk_id == b"ID3 ":
            out.update(_read_id3v2_tags(data[data_start:data_end]))
        offset = data_end + (size % 2)
    return out


def _read_mp4_tags(data: bytes) -> Dict[str, str]:
    out: Dict[str, str] = {}

    def parse(start: int, end: int, *, meta: bool = False) -> None:
        offset = start + 4 if meta else start
        for atom_type, body_start, body_end in _iter_mp4_atoms(data, offset, end):
            if atom_type in {b"\xa9nam", b"\xa9ART", b"aART"}:
                value = _read_mp4_data_atom(data, body_start, body_end)
                if value:
                    key = (
                        "title"
                        if atom_type == b"\xa9nam"
                        else ("albumartist" if atom_type == b"aART" else "artist")
                    )
                    out[key] = value
            elif atom_type in {b"moov", b"udta", b"ilst"}:
                parse(body_start, body_end)
            elif atom_type == b"meta":
                parse(body_start, body_end, meta=True)

    parse(0, len(data))
    return out


def _iter_mp4_atoms(data: bytes, start: int, end: int):
    offset = start
    while offset + 8 <= end and offset + 8 <= len(data):
        size = _be32(data, offset)
        atom_type = data[offset + 4 : offset + 8]
        header_size = 8
        if size == 1:
            if offset + 16 > end:
                break
            size = _be64(data, offset + 8)
            header_size = 16
        elif size == 0:
            size = end - offset
        if size < header_size or offset + size > end or offset + size > len(data):
            break
        yield atom_type, offset + header_size, offset + size
        offset += size


def _read_mp4_data_atom(data: bytes, start: int, end: int) -> Optional[str]:
    for atom_type, body_start, body_end in _iter_mp4_atoms(data, start, end):
        if atom_type == b"data" and body_start + 8 <= body_end:
            return _decode_loose_text(data[body_start + 8 : body_end])
    return None


def _decode_id3_text(data: bytes) -> Optional[str]:
    if not data:
        return None
    encoding = data[0]
    payload = data[1:]
    if encoding == 0:
        return _clean_tag(payload.decode("latin1", errors="replace"))
    if encoding == 1:
        return _clean_tag(_decode_utf16(payload))
    if encoding == 2:
        return _clean_tag(payload.decode("utf-16-be", errors="replace"))
    if encoding == 3:
        return _clean_tag(payload.decode("utf-8", errors="replace"))
    return _decode_loose_text(payload)


def _decode_id3_user_text(data: bytes) -> tuple[Optional[str], Optional[str]]:
    if not data:
        return None, None
    encoding = data[0]
    payload = data[1:]
    if encoding == 0:
        text = payload.decode("latin1", errors="replace")
    elif encoding == 1:
        text = _decode_utf16(payload)
    elif encoding == 2:
        text = payload.decode("utf-16-be", errors="replace")
    else:
        text = payload.decode("utf-8", errors="replace")
    parts = text.split("\x00", 1)
    description = _clean_tag(parts[0])
    value = _clean_tag(parts[1] if len(parts) > 1 else "")
    return description, value


def _id3_user_text_target(description: Optional[str]) -> Optional[str]:
    if description is None:
        return None
    normalized = _normalize_tag_key(description)
    if normalized == "title":
        return "title"
    if normalized in {"albumartist", "album_artist", "album_artists"}:
        return "albumartist"
    if normalized in {"artist", "artists", "performer"}:
        return "artist"
    return None


def _decode_utf16(data: bytes) -> str:
    if data.startswith(b"\xfe\xff") or data.startswith(b"\xff\xfe"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-16-le", errors="replace")


def _decode_loose_text(data: bytes) -> Optional[str]:
    text = data.decode("utf-8", errors="replace")
    if "\ufffd" not in text:
        return _clean_tag(text)
    return _clean_tag(data.decode("latin1", errors="replace"))


def _clean_tag(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    cleaned = value.replace("\ufeff", "").replace("\x00", " ")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned or None


def _positive_float(value: object) -> Optional[float]:
    try:
        number = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _positive_int(value: object) -> Optional[int]:
    try:
        number = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _is_audio_path(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_SUFFIXES


def _be32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "big")


def _be64(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 8], "big")


def _le32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "little")


def _syncsafe32(data: bytes, offset: int) -> int:
    return (
        ((data[offset] & 0x7F) << 21)
        | ((data[offset + 1] & 0x7F) << 14)
        | ((data[offset + 2] & 0x7F) << 7)
        | (data[offset + 3] & 0x7F)
    )
