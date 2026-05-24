from __future__ import annotations

import inspect
import os
import shutil
from pathlib import Path
from typing import Iterable, Optional

DEFAULT_HF_DOWNLOAD_WORKERS = 8
_WORKER_ENV_NAMES = (
    "FH_RADIO_STUDIO_HF_DOWNLOAD_WORKERS",
    "FH_RADIO_STUDIO_HF_MAX_WORKERS",
)


def hf_endpoint() -> Optional[str]:
    for name in ("FH_RADIO_STUDIO_HF_ENDPOINT", "HF_ENDPOINT"):
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip().rstrip("/")
    return None


def hf_download_workers() -> int:
    for name in _WORKER_ENV_NAMES:
        value = os.environ.get(name)
        if not value:
            continue
        try:
            workers = int(value)
        except ValueError:
            continue
        return max(1, min(workers, 64))
    return DEFAULT_HF_DOWNLOAD_WORKERS


def configure_hf_transfer_environment() -> None:
    high_performance = (
        os.environ.get("FH_RADIO_STUDIO_HF_XET_HIGH_PERFORMANCE", "1").strip().lower()
    )
    if high_performance not in {"0", "false", "no", "off"}:
        os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")

    range_gets = os.environ.get("FH_RADIO_STUDIO_HF_XET_RANGE_GETS")
    if range_gets and "HF_XET_NUM_CONCURRENT_RANGE_GETS" not in os.environ:
        os.environ["HF_XET_NUM_CONCURRENT_RANGE_GETS"] = range_gets


def download_hf_snapshot(
    *,
    repo_id: str,
    local_dir: Path,
    repo_type: str = "model",
    allow_patterns: Optional[Iterable[str]] = None,
) -> Path:
    configure_hf_transfer_environment()

    from huggingface_hub import snapshot_download

    local_dir.mkdir(parents=True, exist_ok=True)
    kwargs = {
        "repo_id": repo_id,
        "repo_type": repo_type,
        "local_dir": str(local_dir),
        "allow_patterns": list(allow_patterns) if allow_patterns is not None else None,
        "max_workers": hf_download_workers(),
    }
    endpoint = hf_endpoint()
    if endpoint:
        kwargs["endpoint"] = endpoint

    parameters = inspect.signature(snapshot_download).parameters
    if "resume_download" in parameters:
        kwargs["resume_download"] = True
    if "local_dir_use_symlinks" in parameters:
        kwargs["local_dir_use_symlinks"] = False

    filtered = {
        key: value for key, value in kwargs.items() if key in parameters and value is not None
    }
    snapshot_download(**filtered)
    return local_dir


def remove_invalid_repo_dir(repo_dir: Path, *, provider_dir: Path) -> None:
    if not repo_dir.exists():
        return
    target = repo_dir.resolve()
    owner = provider_dir.resolve()
    if target == owner or owner not in target.parents:
        raise RuntimeError(f"Refusing to remove model path outside provider repo: {repo_dir}")
    if repo_dir.is_dir():
        shutil.rmtree(repo_dir)
    else:
        repo_dir.unlink()
