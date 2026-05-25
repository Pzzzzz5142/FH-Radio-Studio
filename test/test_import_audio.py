from __future__ import annotations

import json
import wave
from pathlib import Path

import soundfile as sf

from backend.fh_radio_studio_cli.cli import main
from backend.fh_radio_studio_cli.metadata import (
    has_import_completion_marker,
    read_track_metadata,
)

_PNG_BYTES = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\xf8"
    b"\x0f\x00\x01\x01\x01\x00\x1f\xef\x03\xfd\x00\x00\x00\x00IEND\xaeB`\x82"
)


def test_import_audio_transcodes_non_48k_file(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    source = tmp_path / "Outside Song.wav"
    _write_pcm_wav(source, sample_rate=44100, frames=4410, channels=2)

    exit_code = main(
        [
            "import-audio",
            str(source),
            "--project-dir",
            str(project),
            "--json",
        ]
    )

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    item = payload["imported"][0]
    imported = Path(item["path"])
    assert item["action"] == "transcoded"
    assert item["source_sample_rate"] == 44100
    assert "loudness_analysis" in item
    assert imported.parent == project / "sources"
    assert sf.info(str(imported)).samplerate == 48000
    assert has_import_completion_marker(imported)
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    cached = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"][0]
    assert cached["source"] == str(imported.resolve())
    assert "loudness_analysis" in cached


def test_import_audio_copies_48k_file_without_transcoding(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    source = tmp_path / "Already 48k.wav"
    _write_pcm_wav(source, sample_rate=48000, frames=4800, channels=2)

    exit_code = main(
        [
            "import-audio",
            str(source),
            "--project-dir",
            str(project),
            "--json",
        ]
    )

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    item = payload["imported"][0]
    imported = Path(item["path"])
    assert item["action"] == "copied"
    assert item["source_sample_rate"] == 48000
    assert imported.name == source.name
    assert sf.info(str(imported)).samplerate == 48000
    assert has_import_completion_marker(imported)
    assert not list((project / "sources").glob("*.fh-radio-studio-import-tmp*"))


def test_import_audio_can_target_siren_folder(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    source = tmp_path / "MSR-232251.wav"
    cover = tmp_path / "cover.png"
    _write_pcm_wav(source, sample_rate=48000, frames=4800, channels=2)
    cover.write_bytes(_PNG_BYTES)

    exit_code = main(
        [
            "import-audio",
            str(source),
            "--project-dir",
            str(project),
            "--target-folder",
            "siren",
            "--title",
            "Whistle Stop",
            "--artist",
            "塞壬唱片-MSR / Edine",
            "--album",
            "巴别塔OST",
            "--cover-image",
            str(cover),
            "--json",
        ]
    )

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    item = payload["imported"][0]
    imported = Path(item["path"])
    assert payload["target_folder"] == "siren"
    assert imported.parent == project / "siren"
    assert imported.name == source.name
    assert item["metadata_tags_written"] is True
    assert not has_import_completion_marker(imported)
    cache_path = project / ".fh-radio-studio" / "track_metadata.json"
    cached = json.loads(cache_path.read_text(encoding="utf-8"))["tracks"][0]
    assert cached["source"] == str(imported.resolve())
    assert "loudness_analysis" in cached
    assert cached["cover_art_mime"] == "image/png"
    assert Path(cached["cover_art_path"]).read_bytes() == _PNG_BYTES
    metadata = read_track_metadata(imported)
    assert metadata.title == "Whistle Stop"
    assert metadata.artist == "塞壬唱片-MSR / Edine"
    assert metadata.from_tags is True


def test_import_audio_keeps_48k_project_source_untouched(tmp_path: Path, capsys) -> None:
    project = tmp_path / "project"
    source = project / "sources" / "Already In Project.wav"
    _write_pcm_wav(source, sample_rate=48000, frames=4800, channels=2)
    before = source.read_bytes()

    exit_code = main(
        [
            "import-audio",
            str(source),
            "--project-dir",
            str(project),
            "--json",
        ]
    )

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    item = payload["imported"][0]
    assert item["action"] == "kept"
    assert Path(item["path"]) == source
    assert source.read_bytes() == before


def _write_pcm_wav(path: Path, *, sample_rate: int, frames: int, channels: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * frames * channels)
