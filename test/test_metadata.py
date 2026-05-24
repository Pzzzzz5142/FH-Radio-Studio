from __future__ import annotations

import json
import wave
from pathlib import Path

from backend.fh_radio_studio_cli.cli import main
from backend.fh_radio_studio_cli.common import guess_metadata
from backend.fh_radio_studio_cli.metadata import read_track_metadata, write_track_metadata_tags

_PNG_BYTES = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\xf8"
    b"\x0f\x00\x01\x01\x01\x00\x1f\xef\x03\xfd\x00\x00\x00\x00IEND\xaeB`\x82"
)


def test_reads_id3_artist_and_title_before_filename_fallback(tmp_path: Path) -> None:
    path = tmp_path / "01 - Wrong Artist - Wrong Title.mp3"
    _write_id3v23(path, title="Nine Sols", artist="Collage")

    metadata = read_track_metadata(path)

    assert metadata.from_tags is True
    assert metadata.artist == "Collage"
    assert metadata.title == "Nine Sols"
    assert guess_metadata(path) == ("Collage", "Nine Sols")


def test_reads_common_mutagen_artist_aliases(tmp_path: Path) -> None:
    path = tmp_path / "01 - Wrong Artist - Wrong Title.mp3"
    _write_id3v23(
        path,
        title="Broken Sun",
        artist=None,
        extra_frames=[_id3_user_text_frame("ARTISTS", "Chris Tilton")],
    )

    metadata = read_track_metadata(path)

    assert metadata.from_tags is True
    assert metadata.artist == "Chris Tilton"
    assert metadata.title == "Broken Sun"


def test_reads_flac_vorbis_comments_before_filename_fallback(tmp_path: Path) -> None:
    path = tmp_path / "02 - Wrong Artist - Wrong Title.flac"
    _write_flac_comments(path, {"TITLE": "Broken Sun", "ARTIST": "Chris Tilton"})

    metadata = read_track_metadata(path)

    assert metadata.from_tags is True
    assert metadata.artist == "Chris Tilton"
    assert metadata.title == "Broken Sun"


def test_reads_wav_id3_chunk_before_filename_fallback(tmp_path: Path) -> None:
    path = tmp_path / "04 - Wrong Artist - Wrong Title.wav"
    _write_wav_with_id3_chunk(path, title="I Will Touch the Sky", artist="塞壬唱片-MSR; Edine")

    metadata = read_track_metadata(path)

    assert metadata.from_tags is True
    assert metadata.artist == "塞壬唱片-MSR; Edine"
    assert metadata.title == "I Will Touch the Sky"


def test_reads_aiff_name_and_author_chunks(tmp_path: Path) -> None:
    path = tmp_path / "05 - Wrong Artist - Wrong Title.aiff"
    _write_aiff_metadata(path, title="Spectrum Self", artist="Mili")

    metadata = read_track_metadata(path)

    assert metadata.from_tags is True
    assert metadata.artist == "Mili"
    assert metadata.title == "Spectrum Self"


def test_falls_back_to_filename_when_tags_are_missing(tmp_path: Path) -> None:
    path = tmp_path / "03 - FH Radio Studio Dev - Fallback Song.wav"
    path.write_bytes(b"RIFF\x00\x00\x00\x00WAVE")

    metadata = read_track_metadata(path)

    assert metadata.from_tags is False
    assert metadata.artist == "FH Radio Studio Dev"
    assert metadata.title == "Fallback Song"


def test_scan_metadata_writes_project_cache(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    sources = project / "sources"
    sources.mkdir(parents=True)
    track = sources / "01 - Wrong Artist - Wrong Title.mp3"
    _write_id3v23(track, title="Everything's Alright", artist="Laura Shigihara")

    exit_code = main(
        [
            "scan-metadata",
            "--project-dir",
            str(project),
            "--all-sources",
            "--json",
        ]
    )

    assert exit_code == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["scanned"] == 1
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    payload = json.loads(cache_path.read_text(encoding="utf-8"))
    assert payload["tracks"][0]["artist"] == "Laura Shigihara"
    assert payload["tracks"][0]["title"] == "Everything's Alright"
    assert payload["tracks"][0]["from_tags"] is True


def test_scan_metadata_writes_audio_info(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    sources = project / "sources"
    sources.mkdir(parents=True)
    track = sources / "01 - FH Radio Studio Dev - Half Second.wav"
    _write_pcm_wav(track, sample_rate=48000, frames=24000, channels=2)

    exit_code = main(
        [
            "scan-metadata",
            "--project-dir",
            str(project),
            "--all-sources",
            "--json",
        ]
    )

    assert exit_code == 0
    _ = capsys.readouterr()
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    item = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"][0]
    assert item["duration_sec"] == 0.5
    assert item["sample_rate"] == 48000
    assert item["channels"] == 2
    assert item["samples"] == 24000


def test_scan_metadata_extracts_embedded_cover_art(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    sources = project / "sources"
    sources.mkdir(parents=True)
    track = sources / "01 - FH Radio Studio Dev - Covered.wav"
    cover = tmp_path / "cover.png"
    _write_pcm_wav(track, sample_rate=48000, frames=24000, channels=2)
    cover.write_bytes(_PNG_BYTES)
    assert write_track_metadata_tags(
        track,
        title="Covered",
        artist="FH Radio Studio Dev",
        cover_image=cover,
    )

    exit_code = main(
        [
            "scan-metadata",
            "--project-dir",
            str(project),
            "--all-sources",
            "--json",
        ]
    )

    assert exit_code == 0
    _ = capsys.readouterr()
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    item = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"][0]
    assert item["cover_art_mime"] == "image/png"
    assert Path(item["cover_art_path"]).parent == project / ".fh-radio-studio" / "artwork"
    assert Path(item["cover_art_path"]).read_bytes() == _PNG_BYTES


def test_scan_metadata_preserves_fresh_loudness_cache(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    sources = project / "sources"
    sources.mkdir(parents=True)
    track = sources / "01 - FH Radio Studio Dev - Cached.wav"
    _write_pcm_wav(track, sample_rate=48000, frames=24000, channels=2)
    stat = track.stat()
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    cache_path.parent.mkdir(parents=True)
    cache_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "tracks": [
                    {
                        "source": str(track.resolve()),
                        "path_key": str(track.resolve()).lower(),
                        "artist": "Old",
                        "title": "Old",
                        "loudness_analysis": {
                            "status": "ok",
                            "algorithm_version": "fh-radio-studio-loudness-v1",
                            "integrated_lufs": -18.0,
                            "true_peak_dbtp": -2.0,
                            "source_size": stat.st_size,
                            "source_mtime_ms": int(stat.st_mtime * 1000),
                            "cached_at": "2026-05-24T00:00:00+00:00",
                        },
                    }
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    exit_code = main(
        [
            "scan-metadata",
            "--project-dir",
            str(project),
            "--all-sources",
            "--json",
        ]
    )

    assert exit_code == 0
    _ = capsys.readouterr()
    item = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"][0]
    assert item["loudness_analysis"]["integrated_lufs"] == -18.0
    assert item["loudness_analysis"]["true_peak_dbtp"] == -2.0


def test_scan_metadata_all_sources_includes_siren_folder(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    sources_track = project / "sources" / "01 - FH Radio Studio Dev - Source.wav"
    siren_track = project / "siren" / "MSR-232251.wav"
    sources_track.parent.mkdir(parents=True)
    siren_track.parent.mkdir(parents=True)
    _write_pcm_wav(sources_track, sample_rate=48000, frames=24000, channels=2)
    _write_pcm_wav(siren_track, sample_rate=48000, frames=24000, channels=2)

    exit_code = main(
        [
            "scan-metadata",
            "--project-dir",
            str(project),
            "--all-sources",
            "--json",
        ]
    )

    assert exit_code == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["scanned"] == 2
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    tracks = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"]
    assert {Path(item["source"]).parent.name for item in tracks} == {
        "sources",
        "siren",
    }


def _write_id3v23(
    path: Path,
    *,
    title: str,
    artist: str | None,
    extra_frames: list[bytes] | None = None,
) -> None:
    frames = b"".join(
        [
            _id3_text_frame("TIT2", title),
            *([_id3_text_frame("TPE1", artist)] if artist else []),
            *(extra_frames or []),
        ]
    )
    path.write_bytes(b"ID3" + bytes([3, 0, 0]) + _syncsafe(len(frames)) + frames + b"audio")


def _id3_text_frame(frame_id: str, value: str) -> bytes:
    payload = b"\x03" + value.encode("utf-8")
    return frame_id.encode("ascii") + len(payload).to_bytes(4, "big") + b"\x00\x00" + payload


def _id3_user_text_frame(description: str, value: str) -> bytes:
    payload = b"\x03" + description.encode("utf-8") + b"\x00" + value.encode("utf-8")
    return b"TXXX" + len(payload).to_bytes(4, "big") + b"\x00\x00" + payload


def _syncsafe(value: int) -> bytes:
    return bytes(
        [
            (value >> 21) & 0x7F,
            (value >> 14) & 0x7F,
            (value >> 7) & 0x7F,
            value & 0x7F,
        ]
    )


def _write_flac_comments(path: Path, comments: dict[str, str]) -> None:
    vendor = b"FHRadioStudioTest"
    entries = [f"{key}={value}".encode("utf-8") for key, value in comments.items()]
    block = (
        len(vendor).to_bytes(4, "little")
        + vendor
        + len(entries).to_bytes(4, "little")
        + b"".join(len(entry).to_bytes(4, "little") + entry for entry in entries)
    )
    path.write_bytes(b"fLaC" + bytes([0x84]) + len(block).to_bytes(3, "big") + block)


def _write_wav_with_id3_chunk(path: Path, *, title: str, artist: str) -> None:
    fmt = (
        (1).to_bytes(2, "little")
        + (2).to_bytes(2, "little")
        + (48000).to_bytes(4, "little")
        + (48000 * 2 * 2).to_bytes(4, "little")
        + (2 * 2).to_bytes(2, "little")
        + (16).to_bytes(2, "little")
    )
    frames = b"\x00\x00" * 480 * 2
    id3 = (
        b"ID3"
        + bytes([4, 0, 0])
        + _syncsafe(len(_id3_text_frame("TIT2", title)) + len(_id3_text_frame("TPE1", artist)))
    )
    id3 += _id3_text_frame("TIT2", title) + _id3_text_frame("TPE1", artist)
    chunks = [
        _riff_chunk(b"fmt ", fmt),
        _riff_chunk(b"data", frames),
        _riff_chunk(b"id3 ", id3),
    ]
    body = b"WAVE" + b"".join(chunks)
    path.write_bytes(b"RIFF" + len(body).to_bytes(4, "little") + body)


def _write_aiff_metadata(path: Path, *, title: str, artist: str) -> None:
    chunks = [
        _aiff_chunk(b"NAME", title.encode("utf-8")),
        _aiff_chunk(b"AUTH", artist.encode("utf-8")),
    ]
    body = b"AIFF" + b"".join(chunks)
    path.write_bytes(b"FORM" + len(body).to_bytes(4, "big") + body)


def _riff_chunk(chunk_id: bytes, payload: bytes) -> bytes:
    padding = b"\x00" if len(payload) % 2 else b""
    return chunk_id + len(payload).to_bytes(4, "little") + payload + padding


def _aiff_chunk(chunk_id: bytes, payload: bytes) -> bytes:
    padding = b"\x00" if len(payload) % 2 else b""
    return chunk_id + len(payload).to_bytes(4, "big") + payload + padding


def _write_pcm_wav(path: Path, *, sample_rate: int, frames: int, channels: int) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * frames * channels)
