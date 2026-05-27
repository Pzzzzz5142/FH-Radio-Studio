from __future__ import annotations

import hashlib
import json
import math
import shutil
import struct
import subprocess
import wave
from dataclasses import dataclass
from pathlib import Path

import pytest

from tools.test.create_mock_game import (
    DEFAULT_BUILD_ID,
    GAME_ROOT_REL,
    PREFERRED_LANG_REL,
    create_mock,
    mock_version_id,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
TMP_FIXTURE_ROOT = REPO_ROOT / "test" / "fixtures" / ".tmp"
PROJECT_ROOT = REPO_ROOT / "test" / "project"


@dataclass(frozen=True)
class MockGame:
    root: Path
    game_dir: Path
    preferred_path: Path


@dataclass(frozen=True)
class TestProject:
    root: Path
    sources_dir: Path
    packages_dir: Path
    backups_dir: Path
    analysis_dir: Path
    metadata_dir: Path


@pytest.fixture
def mock_game() -> MockGame:
    root = TMP_FIXTURE_ROOT / "mock-game" / f"fh6-{mock_version_id(DEFAULT_BUILD_ID)}"
    create_mock(root, reset=True, build_id=DEFAULT_BUILD_ID)
    return MockGame(
        root=root,
        game_dir=root / GAME_ROOT_REL,
        preferred_path=root / PREFERRED_LANG_REL,
    )


@pytest.fixture
def full_project(mock_game: MockGame) -> TestProject:
    root = PROJECT_ROOT / "cli-full-flow"
    if root.exists():
        shutil.rmtree(root)
    sources_dir = root / "sources"
    packages_dir = root / "packages"
    backups_dir = root / "backups"
    analysis_dir = root / "analysis"
    metadata_dir = root / ".fh-radio-studio"
    for directory in (sources_dir, packages_dir, backups_dir, analysis_dir, metadata_dir):
        directory.mkdir(parents=True, exist_ok=True)
    (metadata_dir / "project.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "app": "FH Radio Studio",
                "folders": {
                    "sources": "sources",
                    "packages": "packages",
                    "backups": "backups",
                    "analysis": "analysis",
                },
                "settings": {
                    "game_dir": str(mock_game.game_dir),
                    "source_lang": "CHS",
                    "target_lang": "EN",
                },
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return TestProject(
        root=root,
        sources_dir=sources_dir,
        packages_dir=packages_dir,
        backups_dir=backups_dir,
        analysis_dir=analysis_dir,
        metadata_dir=metadata_dir,
    )


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["uv", "run", "--project", str(REPO_ROOT), "fh-radio-studio", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def assert_cli_ok(result: subprocess.CompletedProcess[str]) -> None:
    assert result.returncode == 0, (
        f"command failed with exit code {result.returncode}\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


def md5_file(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_test_tone(path: Path, duration_sec: float = 1.25, sample_rate: int = 48000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = int(duration_sec * sample_rate)
    amplitude = int(32767 * 0.25)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        for index in range(frames):
            value = int(amplitude * math.sin(2 * math.pi * 440.0 * index / sample_rate))
            frame = struct.pack("<hh", value, value)
            wav.writeframesraw(frame)
