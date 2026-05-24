from __future__ import annotations

import argparse
import hashlib
import json
import locale
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np
import soundfile as sf

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


DEFAULT_STEAM_GAME_DIR = Path(r"C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6")
DEFAULT_PYTHON_VERSION = "3.12"


def env_path(name: str) -> Optional[Path]:
    value = os.environ.get(name)
    if value and value.strip():
        return Path(value).expanduser()
    return None


def python_version() -> str:
    value = os.environ.get("FH_RADIO_STUDIO_PYTHON_VERSION")
    return value.strip() if value and value.strip() else DEFAULT_PYTHON_VERSION


REPO_ROOT = env_path("FH_RADIO_STUDIO_RUNTIME_ROOT") or Path(__file__).resolve().parents[2]
TOOLCHAIN_HOME = (
    env_path("FH_RADIO_STUDIO_TOOLCHAIN_HOME") or REPO_ROOT / ".fh-radio-studio-dev" / "toolchain"
)
VENDORED_TOOLS_DIR = (
    env_path("FH_RADIO_STUDIO_AUDIO_TOOLS_DIR") or TOOLCHAIN_HOME / "tools" / "audio"
)
FFMPEG_VERSION = "8.1.1"
FFMPEG_URL = "https://www.gyan.dev/ffmpeg/builds/packages/" "ffmpeg-8.1.1-essentials_build.zip"
FFMPEG_SHA256 = "6f58ce889f59c311410f7d2b18895b33c03456463486f3b1ebc93d97a0f54541"
VGMSTREAM_VERSION = "r2117"
VGMSTREAM_URL = (
    "https://github.com/vgmstream/vgmstream/releases/download/" "r2117/vgmstream-win64.zip"
)
VGMSTREAM_SHA256 = "6c4a8a3813864fefed081bbd337dbc0ad93bf88e0b92f5db98d7ab258b22dc6c"
FMOD_BUNDLE_COMMIT = "d6f598b49076ca3125f7ac0b95c6db7b763a652b"
FMOD_BUNDLE_VERSION = f"ElRors/ForzaRadioModTool@{FMOD_BUNDLE_COMMIT}"
FMOD_BUNDLE_BASE = (
    "https://raw.githubusercontent.com/ElRors/ForzaRadioModTool/"
    f"{FMOD_BUNDLE_COMMIT}/Tools/FmodBankTools/Fmod/"
)
FMOD_BUNDLE_FILES = (
    "fsbankcl.exe",
    "fmod.dll",
    "libfsbvorbis.dll",
    "libmp3lame.dll",
    "twolame.dll",
    "Qt5Core.dll",
    "libEGL.dll",
    "libGLESv2.dll",
    "msvcp110.dll",
    "msvcr110.dll",
)
FMOD_BUNDLE_SHA256 = {
    "fsbankcl.exe": "27b8ba57b34eba4b0a6e681fe7155f1f301da37d16cf56d0a26cdf2946276274",
    "fmod.dll": "5c6a289a1a53110623e227b0246ff2be4629b3e29319909d44914d8be26aa79b",
    "libfsbvorbis.dll": "752c5fb9733a8116edb031abc145245a86deca2f32e048d14499a7560d5de356",
    "libmp3lame.dll": "f0d6df6ab52ffb650d2f3f9618ccfc72f6e593d25d5b459a8163e79363984169",
    "twolame.dll": "299e81ecc695a5828f8cb25a1b8f77ca3250159db505e723e4746592b90b4ad9",
    "Qt5Core.dll": "e7aaee4b94490f2608ef1d18bad155aec3066ff3f5a1e686a5bb08119c485f8a",
    "libEGL.dll": "374c46d22f5429fe0bdb9a4c214c4f6b6ae87259e539522552707acae713b1e9",
    "libGLESv2.dll": "4cee4f02973b7ad6bf5d0a52becd290d60230d503ac757bc94dd65030c1a9e2e",
    "msvcp110.dll": "c8d5572ca8d7624871188f0acabc3ae60d4c5a4f6782d952b9038de3bc28b39a",
    "msvcr110.dll": "b30160e759115e24425b9bcdf606ef6ebce4657487525ede7f1ac40b90ff7e49",
}
TARGET_SAMPLE_RATE = 48000
FSB5_HEADER_SIZE = 60
FSB5_MAX_SAMPLES = 4096
FSB5_SAMPLE_RATES = {
    0: 4000,
    1: 8000,
    2: 11000,
    3: 11025,
    4: 16000,
    5: 22050,
    6: 24000,
    7: 32000,
    8: 44100,
    9: 48000,
    10: 96000,
}
PLAYLIST_TYPES = ("FreeRoam", "Event")
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
DEFAULT_MARKERS = {name: -1 for name in MARKER_ORDER}
DEFAULT_MARKERS.update(
    {
        "TrackStart": 0,
    }
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


class CliError(Exception):
    pass


def die(message: str) -> None:
    raise CliError(message)


def safe_int(value: Optional[str], default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def s2tc(samples: int, sr: int = TARGET_SAMPLE_RATE) -> str:
    seconds = samples / sr
    minutes = int(seconds // 60)
    rem = seconds % 60
    return f"{minutes}:{rem:06.3f}"


def seconds_to_samples(seconds: Optional[float], sr: int) -> Optional[int]:
    if seconds is None:
        return None
    return int(round(seconds * sr))


def db_to_linear(db: float) -> float:
    return 10 ** (db / 20.0)


def rms_dbfs(data: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt(np.mean(data**2)) + 1e-9))


def peak_dbfs(data: np.ndarray) -> float:
    return float(20 * np.log10(np.abs(data).max() + 1e-9))


def sanitize_token(value: str, fallback: str) -> str:
    asciiish = re.sub(r"[^A-Za-z0-9]+", "_", value.strip())
    asciiish = re.sub(r"_+", "_", asciiish).strip("_")
    return asciiish or fallback


def make_sound_name(radio: int, artist: str, title: str) -> str:
    return f"HZ6_R{radio}_{sanitize_token(artist, 'Artist')}_{sanitize_token(title, 'Track')}"


def make_wav_filename(sound_name: str) -> str:
    return f"{sanitize_token(sound_name, 'track')}.wav"


def guess_metadata(path: Path) -> Tuple[str, str]:
    from .metadata import guess_track_metadata

    return guess_track_metadata(path)


def path_key(path: Path) -> str:
    try:
        return str(path.resolve()).casefold()
    except OSError:
        return str(path.absolute()).casefold()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_json(path: Path, data: Dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def sha256_file(path: Path) -> Optional[str]:
    if not path.exists() or not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def md5_file(path: Path) -> Optional[str]:
    if not path.exists() or not path.is_file():
        return None
    digest = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_size(path: Path) -> Optional[int]:
    if not path.exists() or not path.is_file():
        return None
    return path.stat().st_size


def package_root_dir(package_dir: Path) -> Path:
    if (package_dir / "media").is_dir():
        return package_dir
    if (package_dir / "package" / "media").is_dir():
        return package_dir / "package"
    if package_dir.name.lower() == "audio" and package_dir.parent.name.lower() == "media":
        return package_dir.parent.parent
    die(f"Could not find package media directory under {package_dir}")


def load_manifest(path: Path) -> Dict[str, object]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"Manifest parse failed: {path}: {exc}")
