from __future__ import annotations

import hashlib
import os
import re
import string
from pathlib import Path
from typing import Iterable, Optional
from urllib.parse import unquote_to_bytes

PROJECT_REF_SCHEME = "fh-project"
PROJECT_REF_PREFIX = f"{PROJECT_REF_SCHEME}:/"
PROJECT_REF_ROOTS = {
    ".fh-radio-studio",
    "analysis",
    "backups",
    "packages",
    "siren",
    "sources",
}

_WINDOWS_DRIVE_SEGMENT_RE = re.compile(r"^[A-Za-z]:$")
_INVALID_PERCENT_RE = re.compile(r"%(?![0-9A-Fa-f]{2})")

# RFC 3986 unreserved characters. Both the Dart and Python codecs must encode any
# byte outside this set as upper-case percent escapes so that the same project
# path yields a byte-identical `source_ref` (and therefore an identical
# `track_key`) on every platform. Do not widen this set to match a stdlib helper
# such as `urllib.parse.quote` or Dart's `Uri.encodeComponent`; they disagree on
# characters like `!*'()` and would silently fork the cross-platform identity.
_UNRESERVED_BYTES = frozenset((string.ascii_letters + string.digits + "-._~").encode("ascii"))


class ProjectRefError(ValueError):
    pass


def is_project_ref(value: object) -> bool:
    return isinstance(value, str) and value.startswith(PROJECT_REF_PREFIX)


def normalize_project_ref(value: str) -> str:
    segments = _parse_project_ref_segments(value)
    return _format_project_ref(segments)


def project_ref_for_path(project_dir: Path, path: Path) -> Optional[str]:
    root = absolute_path(project_dir)
    child = absolute_path(path)
    if not _is_same_or_inside(child, root):
        return None
    relative = os.path.relpath(str(child), str(root))
    segments = _normalize_path_parts(Path(relative).parts)
    if not segments:
        return None
    _validate_project_ref_segments(segments)
    return _format_project_ref(segments)


def project_path_or_absolute(project_dir: Path, path: Path) -> str:
    source_ref = project_ref_for_path(project_dir, path)
    if source_ref is not None:
        return source_ref
    return str(absolute_path(path))


def resolve_project_ref(project_dir: Path, source_ref: str) -> Path:
    segments = _parse_project_ref_segments(source_ref)
    root = absolute_path(project_dir)
    resolved = absolute_path(root.joinpath(*segments))
    if not _is_same_or_inside(resolved, root):
        raise ProjectRefError(f"Project ref escapes project root: {source_ref}")
    return resolved


def track_key_for_source_ref(source_ref: str) -> str:
    canonical = normalize_project_ref(source_ref)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return f"trkref_{digest[:32]}"


def track_key_for_project_path(project_dir: Path, path: Path) -> Optional[str]:
    source_ref = project_ref_for_path(project_dir, path)
    if source_ref is None:
        return None
    return track_key_for_source_ref(source_ref)


def _parse_project_ref_segments(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not value.startswith(PROJECT_REF_PREFIX):
        raise ProjectRefError(f"Invalid project ref scheme: {value!r}")
    raw_path = value[len(PROJECT_REF_PREFIX) :]
    if not raw_path or raw_path.startswith("/"):
        raise ProjectRefError(f"Invalid project ref path: {value!r}")
    if "?" in raw_path or "#" in raw_path:
        raise ProjectRefError(
            f"Project ref path must percent-encode reserved characters: {value!r}"
        )
    if _INVALID_PERCENT_RE.search(raw_path):
        raise ProjectRefError(f"Invalid percent escape in project ref: {value!r}")

    decoded_segments: list[str] = []
    for raw_segment in raw_path.split("/"):
        if raw_segment in {"", "."}:
            continue
        if raw_segment == "..":
            raise ProjectRefError(f"Project ref cannot contain '..': {value!r}")
        try:
            segment = unquote_to_bytes(raw_segment).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ProjectRefError(f"Project ref segment is not UTF-8: {value!r}") from exc
        _validate_decoded_segment(segment, value)
        decoded_segments.append(segment)

    segments = tuple(decoded_segments)
    if not segments:
        raise ProjectRefError(f"Project ref path is empty: {value!r}")
    _validate_project_ref_segments(segments)
    return segments


def _normalize_path_parts(parts: Iterable[str]) -> tuple[str, ...]:
    out: list[str] = []
    for raw in parts:
        if raw in {"", "."}:
            continue
        if raw == "..":
            raise ProjectRefError("Project path cannot contain '..'")
        _validate_decoded_segment(raw, raw)
        out.append(raw)
    return tuple(out)


def _validate_project_ref_segments(segments: tuple[str, ...]) -> None:
    if not segments:
        raise ProjectRefError("Project ref path is empty")
    if segments[0] not in PROJECT_REF_ROOTS:
        raise ProjectRefError(f"Project ref root is not allowed: {segments[0]}")
    for segment in segments:
        _validate_decoded_segment(segment, "/".join(segments))


def _validate_decoded_segment(segment: str, source: str) -> None:
    if not segment or segment in {".", ".."}:
        raise ProjectRefError(f"Invalid project ref segment: {source!r}")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in segment):
        raise ProjectRefError(f"Project ref segment contains a control character: {source!r}")
    if "/" in segment or "\\" in segment:
        raise ProjectRefError(f"Project ref segment contains a path separator: {source!r}")
    if _WINDOWS_DRIVE_SEGMENT_RE.match(segment):
        raise ProjectRefError(f"Project ref segment contains a Windows drive: {source!r}")


def _format_project_ref(segments: tuple[str, ...]) -> str:
    return PROJECT_REF_PREFIX + "/".join(_encode_segment(segment) for segment in segments)


def _encode_segment(segment: str) -> str:
    out: list[str] = []
    for byte in segment.encode("utf-8"):
        if byte in _UNRESERVED_BYTES:
            out.append(chr(byte))
        else:
            out.append(f"%{byte:02X}")
    return "".join(out)


def absolute_path(path: Path) -> Path:
    """Return an absolute, lexically normalized path without resolving links."""
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def _is_same_or_inside(child: Path, parent: Path) -> bool:
    child_text = os.path.normcase(os.path.normpath(str(child)))
    parent_text = os.path.normcase(os.path.normpath(str(parent)))
    if child_text == parent_text:
        return True
    return child_text.startswith(parent_text.rstrip(os.sep) + os.sep)
