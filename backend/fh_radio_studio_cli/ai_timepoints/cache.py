from __future__ import annotations

from pathlib import Path
from typing import Dict, Iterable, List, Optional

from ..common import TOOLCHAIN_HOME, env_path, python_version, sha256_file, write_json

PROVIDER_INSTALL_SPECS: Dict[str, Dict[str, object]] = {
    "baseline_mir": {
        "runtime_packages": ["numpy", "soundfile"],
        "dependency_groups": [],
        "cache_subdir": None,
        "offline_warmup": "No Warmup needed.",
    },
    "beat_this": {
        "runtime_packages": ["beat-this", "torch", "torchaudio"],
        "dependency_groups": ["ai-beat-this"],
        "cache_subdir": "beat_this",
        "offline_warmup": "Run Beat This once with checkpoint final0 and keep the checkpoint/cache under this provider directory.",
    },
    "songformer": {
        "runtime_packages": [
            "torch",
            "transformers",
            "huggingface-hub",
            "librosa",
            "muq",
            "msaf",
            "triton/triton-windows",
            "x-transformers",
        ],
        "dependency_groups": ["ai-songformer"],
        "cache_subdir": "songformer",
        "replaceable_model_subdir": "songformer/repo",
        "model_id": "ASLP-lab/SongFormer",
        "offline_warmup": "Place a valid ASLP-lab/SongFormer snapshot under songformer/repo, or let Warmup download it there and load it once before offline analysis.",
        "notes": [
            "SongFormer is a Hugging Face remote-code model; dependencies are declared in the ai-songformer group."
        ],
    },
    "mert": {
        "runtime_packages": ["torch", "transformers", "torchaudio"],
        "dependency_groups": ["ai-mert"],
        "cache_subdir": "mert",
        "replaceable_model_subdir": "mert/repo",
        "model_id": "m-a-p/MERT-v1-95M",
        "offline_warmup": "Place a valid m-a-p/MERT-v1-95M snapshot under mert/repo, or let Warmup download it there and load it once before offline analysis.",
    },
    "demucs": {
        "runtime_packages": ["demucs"],
        "dependency_groups": ["ai-demucs"],
        "cache_subdir": "demucs",
        "model_id": "htdemucs",
        "offline_warmup": "Download/warm htdemucs weights into the local torch hub cache before offline analysis.",
    },
}

PROFILE_SYNC_GROUPS: Dict[str, List[str]] = {
    "local-base": [],
    "local-deep": ["ai-beat-this", "ai-mert", "ai-songformer"],
    "local-heavy": ["ai-beat-this", "ai-mert", "ai-songformer", "ai-demucs"],
}


def default_model_dir() -> Path:
    return env_path("FH_RADIO_STUDIO_AI_MODEL_DIR") or TOOLCHAIN_HOME / "tools" / "ai" / "models"


def torch_install_plan() -> Dict[str, object]:
    return {
        "package_manager": "uv",
        "selection": "runtime-detected-extra",
        "extras": ["torch-cpu", "torch-cu128"],
        "default_extra": "torch-cpu",
        "note": (
            "Torch wheels are restored through uv project extras. The app/bootstrap selects "
            "`torch-cu128` when an NVIDIA GPU is detected on Windows/Linux, otherwise `torch-cpu`."
        ),
    }


def profile_sync_plan(profile: str) -> Dict[str, object]:
    groups = PROFILE_SYNC_GROUPS.get(profile, [])
    group_args = " ".join(f"--group {group}" for group in groups)
    command = f"uv sync --python {python_version()} --managed-python" + (
        f" {group_args}" if group_args else ""
    )
    return {
        "package_manager": "uv",
        "groups": groups,
        "torch_extras": ["torch-cpu", "torch-cu128"] if groups else [],
        "command": command + (" --extra <torch-cpu|torch-cu128>" if groups else ""),
        "powershell": command + (" --extra <torch-cpu|torch-cu128>" if groups else ""),
        "note": "Dependencies are restored from pyproject.toml and uv.lock; no imperative package install step is part of the product path.",
    }


def _provider_install_entry(model_dir: Path, name: str) -> Dict[str, object]:
    spec = dict(PROVIDER_INSTALL_SPECS.get(name, {}))
    subdir = spec.get("cache_subdir")
    cache_dir = model_dir / str(subdir) if subdir else None
    if cache_dir:
        cache_dir.mkdir(parents=True, exist_ok=True)
    entry: Dict[str, object] = {
        "name": name,
        "status": "planned" if name != "baseline_mir" else "ready",
        "runtime_packages": spec.get("runtime_packages", []),
        "dependency_groups": spec.get("dependency_groups", []),
        "requires_torch": name in {"beat_this", "songformer", "mert", "demucs"},
        "cache_dir": str(cache_dir.resolve()) if cache_dir else None,
        "offline_warmup": spec.get("offline_warmup", ""),
    }
    replaceable_subdir = spec.get("replaceable_model_subdir")
    if replaceable_subdir:
        entry["replaceable_model_dir"] = str((model_dir / str(replaceable_subdir)).resolve())
    for key in ("model_id", "notes"):
        if key in spec:
            entry[key] = spec[key]
    return entry


def write_install_manifest(model_dir: Path, profile: str, providers: Iterable[str]) -> Path:
    provider_entries: List[Dict[str, object]] = [
        _provider_install_entry(model_dir, name) for name in providers
    ]
    manifest = {
        "schema_version": 1,
        "profile": profile,
        "model_dir": str(model_dir.resolve()),
        "runtime_network_required": False,
        "install_network_required": True,
        "package_manager": "uv",
        "dependency_sync": profile_sync_plan(profile),
        "torch": torch_install_plan(),
        "providers": provider_entries,
    }
    path = model_dir / "ai_tools_manifest.json"
    write_json(path, manifest)
    return path


def build_cache_manifest(
    source: Path,
    duration_sec: float,
    source_sample_rate: int,
    profile: str,
    provider_caches: Optional[Dict[str, Dict[str, object]]] = None,
) -> Dict[str, object]:
    return {
        "schema_version": 1,
        "source_path": str(source.resolve()),
        "source_sha256": sha256_file(source),
        "duration_sec": round(float(duration_sec), 3),
        "analysis_sample_rate": int(source_sample_rate),
        "write_sample_rate": 48000,
        "profile": profile,
        "providers": provider_caches or {},
    }
