from __future__ import annotations

import importlib
import importlib.metadata
import importlib.util
import shutil
from pathlib import Path
from typing import Iterable, Optional, Tuple


def module_exists(name: str) -> bool:
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ModuleNotFoundError, ValueError):
        return False


def package_version(*names: str) -> Optional[str]:
    for name in names:
        try:
            return importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            continue
    return None


def import_probe(name: str) -> Tuple[bool, Optional[str]]:
    try:
        importlib.import_module(name)
        return True, None
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"


def executable_path(name: str) -> Optional[str]:
    return shutil.which(name)


def cache_has_any(root: Path, patterns: Iterable[str]) -> bool:
    for pattern in patterns:
        if any(root.glob(pattern)):
            return True
    return False


def torch_device() -> str:
    if not module_exists("torch"):
        return "unavailable"
    try:
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    except Exception:
        return "unknown"
