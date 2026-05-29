from __future__ import annotations

import json
from pathlib import Path
from typing import List, Tuple

from conftest import assert_cli_ok, run_cli

from backend.fh_radio_studio_cli.reconstruct_plan import (
    is_ui_supported_radio,
    reconstruct_playlist_plan,
)


def _radio_info_xml(
    samples: List[Tuple[str, str, str]],
    playlist: List[str],
    *,
    number: int = 4,
    name: str = "Horizon XS",
) -> str:
    sample_xml = "\n".join(
        f'<Sample SoundName="{sound}" DisplayName="{title}" Artist="{artist}" />'
        for sound, title, artist in samples
    )
    entry_xml = "\n".join(f'<Entry Name="{sound}" />' for sound in playlist)
    return f"""<RadioInfo>
  <RadioStations>
    <RadioStation Number="{number}" Name="{name}">
      <SampleList Type="Track">
{sample_xml}
      </SampleList>
      <PlayList Type="FreeRoam">
{entry_xml}
      </PlayList>
    </RadioStation>
  </RadioStations>
</RadioInfo>
"""


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _setup_diff_dirs(tmp_path: Path) -> Tuple[Path, Path, Path]:
    game_audio = tmp_path / "game" / "media" / "audio"
    baseline_audio = tmp_path / "baseline" / "media" / "audio"
    sources = tmp_path / "sources"
    _write(
        baseline_audio / "RadioInfo_CHS.xml",
        _radio_info_xml([("HZ6_BASE", "Base Song", "Base Artist")], ["HZ6_BASE"]),
    )
    _write(
        game_audio / "RadioInfo_CHS.xml",
        _radio_info_xml([("HZ6_CUSTOM", "Diff Song", "Local Artist")], ["HZ6_CUSTOM"]),
    )
    # Filename fallback resolves to artist="Local Artist", title="Diff Song".
    source = sources / "Local Artist - Diff Song.wav"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"")
    return game_audio, baseline_audio, sources


def test_reconstruct_resolves_changed_track_to_source(tmp_path: Path) -> None:
    game_audio, baseline_audio, sources = _setup_diff_dirs(tmp_path)

    assignments = reconstruct_playlist_plan(
        game_audio_dir=game_audio,
        baseline_audio_dir=baseline_audio,
        music_dirs=[sources],
        metadata_cache=None,
        source_lang="CHS",
        target_lang="EN",
    )

    # FreeRoam differs explicitly; Event falls back to sample order and also differs.
    assert len(assignments) == 2
    types = {item["playlist_type"] for item in assignments}
    assert types == {"FreeRoam", "Event"}
    for item in assignments:
        assert item["radio_code"] == "XS"
        assert item["slot"] == 1
        assert Path(str(item["source"])).name == "Local Artist - Diff Song.wav"


def test_reconstruct_uses_metadata_cache_titles(tmp_path: Path) -> None:
    game_audio, baseline_audio, sources = _setup_diff_dirs(tmp_path)
    # Rename the file so the filename no longer matches; only the cache title does.
    renamed = sources / "track-001.wav"
    (sources / "Local Artist - Diff Song.wav").rename(renamed)
    cache = tmp_path / "track_metadata.json"
    cache.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "tracks": [
                    {
                        "source": str(renamed.resolve()),
                        "artist": "Local Artist",
                        "title": "Diff Song",
                        "from_tags": True,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    assignments = reconstruct_playlist_plan(
        game_audio_dir=game_audio,
        baseline_audio_dir=baseline_audio,
        music_dirs=[sources],
        metadata_cache=cache,
        source_lang="CHS",
        target_lang="EN",
    )

    assert len(assignments) == 2
    assert all(Path(str(item["source"])).name == "track-001.wav" for item in assignments)


def test_reconstruct_skips_unchanged_radio(tmp_path: Path) -> None:
    game_audio, baseline_audio, sources = _setup_diff_dirs(tmp_path)
    # Make the game RadioInfo identical to the baseline.
    _write(
        game_audio / "RadioInfo_CHS.xml",
        _radio_info_xml([("HZ6_BASE", "Base Song", "Base Artist")], ["HZ6_BASE"]),
    )

    assignments = reconstruct_playlist_plan(
        game_audio_dir=game_audio,
        baseline_audio_dir=baseline_audio,
        music_dirs=[sources],
        metadata_cache=None,
        source_lang="CHS",
        target_lang="EN",
    )

    assert assignments == []


def test_is_ui_supported_radio_filters_streamer_by_name_only() -> None:
    assert is_ui_supported_radio("Horizon XS") is True
    # Radio number is irrelevant; only the station name gates visibility.
    assert is_ui_supported_radio("Streamer Mode") is False
    assert is_ui_supported_radio("  streamer mode  ") is False
    assert is_ui_supported_radio("Anything") is True


def test_reconstruct_plan_command_writes_plan_file(tmp_path: Path) -> None:
    game_audio, _baseline_audio, sources = _setup_diff_dirs(tmp_path)
    game_dir = tmp_path / "game"
    baseline_manifest = tmp_path / "baseline" / "baseline_manifest.json"
    baseline_manifest.write_text(
        json.dumps({"kind": "game_baseline", "state": "current"}), encoding="utf-8"
    )
    out_path = tmp_path / "playlist_plan.json"

    result = run_cli(
        "reconstruct-plan",
        "--game-dir",
        str(game_dir),
        "--baseline-manifest",
        str(baseline_manifest),
        "--music-dir",
        str(sources),
        "--source",
        "CHS",
        "--target",
        "EN",
        "--out",
        str(out_path),
    )

    assert_cli_ok(result)
    payload = json.loads(out_path.read_text(encoding="utf-8"))
    assert payload["schema_version"] == 2
    assert len(payload["assignments"]) == 2
    assert {item["radio_code"] for item in payload["assignments"]} == {"XS"}
