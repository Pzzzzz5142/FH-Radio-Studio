from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

from .project_refs import (
    ProjectRefError,
    absolute_path,
    is_project_ref,
    normalize_project_ref,
    project_ref_for_path,
)

PROJECT_JSON_PATH_FIELDS = {
    "source",
    "path",
    "cover_art_path",
    "backup_path",
    "package_path",
    "package_audio",
    "source_baseline_manifest",
    "source_package_manifest",
    "package_root",
    "playlist_plan",
    "timing_manifest",
    "baseline_manifest",
    "source_audio_dir",
    "source_radio_info",
    "source_bank",
    "prepared_wav",
    "staged_wav",
    "source_string_tables_dir",
    "source_table",
    "target_table",
    "packaged_table",
}


@dataclass(frozen=True)
class ProjectJsonPathViolation:
    pointer: str
    field: str
    value: str
    message: str


class ProjectJsonPathSchemaError(ValueError):
    def __init__(
        self,
        *,
        project_dir: Path,
        violations: list[ProjectJsonPathViolation],
        path: Optional[Path] = None,
    ) -> None:
        self.project_dir = project_dir
        self.violations = violations
        self.path = path
        target = str(path) if path is not None else "project JSON"
        preview = "; ".join(
            f"{item.pointer}: {item.message} ({item.value})" for item in violations[:5]
        )
        if len(violations) > 5:
            preview += f"; ... {len(violations) - 5} more"
        super().__init__(
            f"{target} has {len(violations)} project path schema violation(s): {preview}"
        )


def find_project_json_path_violations(
    project_dir: Path,
    payload: object,
    *,
    path_fields: Iterable[str] = PROJECT_JSON_PATH_FIELDS,
) -> list[ProjectJsonPathViolation]:
    root = absolute_path(project_dir)
    fields = set(path_fields)
    violations: list[ProjectJsonPathViolation] = []

    def walk(value: object, pointer: list[str], field: Optional[str]) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                walk(child, [*pointer, str(key)], str(key))
            return
        if isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, [*pointer, str(index)], field)
            return
        if field is None or field not in fields or not isinstance(value, str):
            return

        text = value.strip()
        if not text:
            return
        location = _json_pointer(pointer)
        if is_project_ref(text):
            try:
                normalize_project_ref(text)
            except ProjectRefError as exc:
                violations.append(ProjectJsonPathViolation(location, field, text, str(exc)))
            return
        path = Path(text).expanduser()
        if not path.is_absolute():
            return
        if project_ref_for_path(root, path) is None:
            return
        violations.append(
            ProjectJsonPathViolation(
                location,
                field,
                text,
                "project-owned absolute path must be written as fh-project:/",
            )
        )

    walk(payload, [], None)
    return violations


def assert_project_json_path_schema(
    project_dir: Path,
    payload: object,
    *,
    path: Optional[Path] = None,
    path_fields: Iterable[str] = PROJECT_JSON_PATH_FIELDS,
) -> None:
    violations = find_project_json_path_violations(
        project_dir,
        payload,
        path_fields=path_fields,
    )
    if not violations:
        return
    raise ProjectJsonPathSchemaError(
        project_dir=absolute_path(project_dir),
        path=path,
        violations=violations,
    )


def write_project_json(
    path: Path,
    data: object,
    *,
    project_dir: Optional[Path] = None,
    path_fields: Iterable[str] = PROJECT_JSON_PATH_FIELDS,
) -> None:
    resolved_project_dir = project_dir or project_dir_for_project_json_path(path)
    if resolved_project_dir is not None:
        assert_project_json_path_schema(
            resolved_project_dir,
            data,
            path=path,
            path_fields=path_fields,
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def project_dir_for_project_json_path(path: Path) -> Optional[Path]:
    resolved = absolute_path(path)
    parent = resolved.parent
    if parent.name in {".fh-radio-studio", "analysis", "siren"}:
        return parent.parent
    parents = list(resolved.parents)
    if len(parents) > 3 and parents[2].name == "packages":
        return parents[3]
    if len(parents) > 2 and parents[1].name == "backups":
        return parents[2]
    if len(parents) > 3 and parents[2].name == "backups":
        return parents[3]
    return None


def _json_pointer(segments: list[str]) -> str:
    if not segments:
        return "/"
    return "".join(f"/{segment.replace('~', '~0').replace('/', '~1')}" for segment in segments)
