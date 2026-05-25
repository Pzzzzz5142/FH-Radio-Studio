from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PACKAGE_NAME = "fh-radio-studio"
RUNTIME_PROJECT_NAME = "fh-radio-studio-runtime"
BEAT_THIS_CHECKPOINT_URL = (
    "https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt"
)
BEAT_THIS_CHECKPOINT_RELATIVE = (
    Path("beat_this") / "torch_home" / "hub" / "checkpoints" / "beat_this-final0.ckpt"
)
BEAT_THIS_CHECKPOINT_MIN_BYTES = 50 * 1024 * 1024
AUDIO_TOOL_CHECKS = (
    ("ffmpeg", Path("ffmpeg") / "ffmpeg.exe"),
    ("vgmstream-cli", Path("vgmstream") / "vgmstream-cli.exe"),
    ("fsbankcl", Path("fmod") / "fsbankcl.exe"),
)
AUDIO_TOOL_PROBES = {
    "ffmpeg": (["-version"], ("ffmpeg version",)),
    "vgmstream-cli": (["-h"], ("vgmstream cli decoder",)),
    "fsbankcl": (["-help"], ("fmod soundbank generator",)),
}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare the offline uv runtime inputs used by release bundles."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root. Defaults to the parent of tools/.",
    )
    parser.add_argument(
        "--runtime-dir",
        type=Path,
        default=Path(".fh-radio-studio-dev/release-inputs/runtime"),
        help="Output runtime project directory copied next to the app.",
    )
    parser.add_argument(
        "--toolchain-dir",
        type=Path,
        default=Path(".fh-radio-studio-dev/release-inputs/toolchain"),
        help="Output toolchain directory copied next to the app.",
    )
    parser.add_argument(
        "--uv-exe",
        default=os.environ.get("FH_RADIO_STUDIO_DEV_UV_EXE") or "uv",
        help="uv executable used to build and seed the runtime.",
    )
    parser.add_argument(
        "--python",
        default="3.12",
        help="uv-managed Python version to lock and seed.",
    )
    parser.add_argument(
        "--clear",
        action="store_true",
        help="Remove the output runtime/toolchain directories before preparing.",
    )
    parser.add_argument(
        "--skip-sync",
        action="store_true",
        help="Only build the wheel and lock the runtime project; do not seed cache/Python.",
    )
    parser.add_argument(
        "--skip-uv-copy",
        action="store_true",
        help="Do not copy uv into .fh-radio-studio-dev/release-inputs/uv/<platform>/.",
    )
    parser.add_argument(
        "--audio-tools-source-dir",
        type=Path,
        help=(
            "Directory containing ffmpeg/, vgmstream/, and fmod/ to copy into "
            "the release toolchain. Defaults to the dev toolchain; if it is "
            "missing, fh-radio-studio install-tools downloads a fresh copy."
        ),
    )
    parser.add_argument(
        "--skip-audio-tools",
        action="store_true",
        help="Do not prepare bundled audio tools.",
    )
    parser.add_argument(
        "--ai-models-source-dir",
        type=Path,
        help=(
            "Directory containing AI model cache files to copy into the release "
            "toolchain. Only the small Beat This final0 checkpoint is bundled."
        ),
    )
    parser.add_argument(
        "--skip-ai-models",
        action="store_true",
        help="Do not prepare bundled AI model cache files.",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    runtime_dir = resolve_output_path(repo_root, args.runtime_dir)
    toolchain_dir = resolve_output_path(repo_root, args.toolchain_dir)
    wheel_dir = runtime_dir / "wheels"
    cache_dir = toolchain_dir / "uv" / "cache"
    python_dir = toolchain_dir / "python"
    audio_tools_dir = toolchain_dir / "tools" / "audio"
    ai_models_dir = toolchain_dir / "tools" / "ai" / "models"
    packaged_envs_dir = toolchain_dir / "envs"
    seed_env_dir = toolchain_dir / ".seed-env"
    tool_install_env_dir = toolchain_dir / ".tool-install-env"

    if args.clear:
        remove_dir(runtime_dir)
        remove_dir(toolchain_dir)

    wheel_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)
    python_dir.mkdir(parents=True, exist_ok=True)
    remove_dir(packaged_envs_dir)
    remove_dir(seed_env_dir)
    remove_dir(tool_install_env_dir)

    root_pyproject = read_pyproject(repo_root / "pyproject.toml")
    version = root_pyproject["project"]["version"]

    run(
        [
            args.uv_exe,
            "build",
            "--wheel",
            "--out-dir",
            str(wheel_dir),
            "--python",
            args.python,
            "--managed-python",
            str(repo_root),
        ],
        cwd=repo_root,
    )
    wheel = newest_wheel(wheel_dir, PACKAGE_NAME, version)
    write_runtime_pyproject(
        runtime_dir / "pyproject.toml",
        root_pyproject,
        wheel.name,
        args.python,
    )
    old_lock = runtime_dir / "uv.lock"
    if old_lock.exists():
        old_lock.unlink()

    run(
        [
            args.uv_exe,
            "lock",
            "--project",
            str(runtime_dir),
            "--python",
            args.python,
            "--managed-python",
        ],
        cwd=repo_root,
        env=runtime_env(cache_dir, python_dir),
    )

    if not args.skip_sync:
        try:
            run(
                [
                    args.uv_exe,
                    "sync",
                    "--project",
                    str(runtime_dir),
                    "--no-dev",
                    "--locked",
                    "--python",
                    args.python,
                    "--managed-python",
                    "--no-editable",
                    "--compile-bytecode",
                ],
                cwd=repo_root,
                env=runtime_env(cache_dir, python_dir, seed_env_dir),
            )
        finally:
            remove_dir(seed_env_dir)

    if not args.skip_audio_tools:
        prepare_audio_tools(
            repo_root=repo_root,
            destination=audio_tools_dir,
            explicit_source=args.audio_tools_source_dir,
            uv_exe=args.uv_exe,
            python=args.python,
            cache_dir=cache_dir,
            python_dir=python_dir,
            tool_install_env_dir=tool_install_env_dir,
        )

    if not args.skip_ai_models:
        prepare_ai_models(
            repo_root=repo_root,
            destination=ai_models_dir,
            explicit_source=args.ai_models_source_dir,
        )

    if not args.skip_uv_copy:
        copy_uv(args.uv_exe, repo_root)

    print(f"Prepared release runtime: {runtime_dir}")
    print(f"Prepared release toolchain: {toolchain_dir}")
    return 0


def resolve_output_path(repo_root: Path, path: Path) -> Path:
    return path.resolve() if path.is_absolute() else (repo_root / path).resolve()


def remove_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)


def read_pyproject(path: Path) -> dict[str, Any]:
    with path.open("rb") as f:
        return tomllib.load(f)


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
) -> None:
    print("+ " + " ".join(quote_command_part(part) for part in command))
    subprocess.run(command, cwd=cwd, env=env, check=True)


def quote_command_part(part: str) -> str:
    if re.search(r'\s|"', part):
        return '"' + part.replace('"', r"\"") + '"'
    return part


def runtime_env(
    cache_dir: Path,
    python_dir: Path,
    project_environment: Path | None = None,
) -> dict[str, str]:
    env = os.environ.copy()
    env["UV_CACHE_DIR"] = str(cache_dir)
    env["UV_PYTHON_INSTALL_DIR"] = str(python_dir)
    env["UV_MANAGED_PYTHON"] = "true"
    if project_environment is not None:
        env["UV_PROJECT_ENVIRONMENT"] = str(project_environment)
    return env


def prepare_audio_tools(
    *,
    repo_root: Path,
    destination: Path,
    explicit_source: Path | None,
    uv_exe: str,
    python: str,
    cache_dir: Path,
    python_dir: Path,
    tool_install_env_dir: Path,
) -> None:
    source = find_audio_tools_source(repo_root, explicit_source)
    if source is not None:
        print(f"Copying audio tools: {source} -> {destination}")
        remove_dir(destination)
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        assert_audio_tools_ready(destination)
        write_release_audio_tools_manifest(destination, source)
        return

    print(
        "No complete audio tools source found; downloading through fh-radio-studio install-tools."
    )
    remove_dir(destination)
    remove_dir(tool_install_env_dir)
    try:
        run(
            [
                uv_exe,
                "run",
                "--project",
                str(repo_root),
                "--no-dev",
                "--python",
                python,
                "--managed-python",
                "fh-radio-studio",
                "install-tools",
                "--tools-dir",
                str(destination),
                "--force",
            ],
            cwd=repo_root,
            env=runtime_env(cache_dir, python_dir, tool_install_env_dir),
        )
    finally:
        remove_dir(tool_install_env_dir)
    assert_audio_tools_ready(destination)


def find_audio_tools_source(repo_root: Path, explicit_source: Path | None) -> Path | None:
    candidates: list[Path] = []
    if explicit_source is not None:
        candidates.append(resolve_output_path(repo_root, explicit_source))
    candidates.extend(
        [
            repo_root / ".fh-radio-studio-dev" / "toolchain" / "tools" / "audio",
        ]
    )
    for candidate in candidates:
        if audio_tools_ready(candidate):
            return candidate.resolve()
    if explicit_source is not None:
        raise FileNotFoundError(
            f"Audio tools source is incomplete: {resolve_output_path(repo_root, explicit_source)}"
        )
    return None


def audio_tools_ready(path: Path) -> bool:
    return all(audio_tool_ready(path, name, relative) for name, relative in AUDIO_TOOL_CHECKS)


def assert_audio_tools_ready(path: Path) -> None:
    missing = [
        name for name, relative in AUDIO_TOOL_CHECKS if not audio_tool_ready(path, name, relative)
    ]
    if missing:
        raise FileNotFoundError(
            f"Prepared audio tools are incomplete or failed probes under {path}: {', '.join(missing)}"
        )


def audio_tool_ready(base: Path, name: str, relative: Path) -> bool:
    executable = base / relative
    if not executable.exists():
        return False
    args, markers = AUDIO_TOOL_PROBES[name]
    try:
        result = subprocess.run(
            [str(executable), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    output = result.stdout.lower()
    return result.returncode == 0 or any(marker in output for marker in markers)


def write_release_audio_tools_manifest(destination: Path, source: Path) -> None:
    manifest_path = destination / "audio_tools_manifest.json"
    manifest: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            manifest = {}
    release_copy = {
        "source_dir": str(source),
        "copied_at": datetime.now(timezone.utc).isoformat(),
        "notes": "Bundled into release inputs; fh-radio-studio install-tools --force remains the repair fallback.",
    }
    manifest["release_copy"] = release_copy
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def prepare_ai_models(
    *,
    repo_root: Path,
    destination: Path,
    explicit_source: Path | None,
) -> None:
    checkpoint = destination / BEAT_THIS_CHECKPOINT_RELATIVE
    source = find_beat_this_checkpoint_source(repo_root, explicit_source)
    if source is not None:
        print(f"Copying Beat This final0 checkpoint: {source} -> {checkpoint}")
        checkpoint.parent.mkdir(parents=True, exist_ok=True)
        if source.resolve() != checkpoint.resolve():
            shutil.copy2(source, checkpoint)
    else:
        print(f"Downloading Beat This final0 checkpoint: {BEAT_THIS_CHECKPOINT_URL}")
        download_file(BEAT_THIS_CHECKPOINT_URL, checkpoint)
    assert_beat_this_checkpoint_ready(checkpoint)
    write_release_ai_models_manifest(destination, checkpoint, source)


def find_beat_this_checkpoint_source(
    repo_root: Path,
    explicit_source: Path | None,
) -> Path | None:
    candidates: list[Path] = []
    if explicit_source is not None:
        candidates.append(resolve_output_path(repo_root, explicit_source))
    candidates.extend(
        [
            repo_root / ".fh-radio-studio-dev" / "toolchain" / "tools" / "ai" / "models",
            repo_root
            / ".fh-radio-studio-dev"
            / "release-inputs"
            / "toolchain"
            / "tools"
            / "ai"
            / "models",
            Path.home() / ".cache" / "torch",
        ]
    )
    for candidate in candidates:
        checkpoint = find_beat_this_checkpoint(candidate)
        if checkpoint is not None:
            return checkpoint.resolve()
    if explicit_source is not None:
        raise FileNotFoundError(
            f"Beat This final0 checkpoint not found under {resolve_output_path(repo_root, explicit_source)}"
        )
    return None


def find_beat_this_checkpoint(path: Path) -> Path | None:
    if path.is_file() and beat_this_checkpoint_ready(path):
        return path
    if not path.is_dir():
        return None
    direct_candidates = [
        path / BEAT_THIS_CHECKPOINT_RELATIVE,
        path / "hub" / "checkpoints" / "beat_this-final0.ckpt",
        path / "checkpoints" / "beat_this-final0.ckpt",
        path / "beat_this-final0.ckpt",
    ]
    for candidate in direct_candidates:
        if beat_this_checkpoint_ready(candidate):
            return candidate
    for pattern in ("beat_this-final0.ckpt", "final0.ckpt", "beat_this/**/*.ckpt"):
        for candidate in path.glob(pattern):
            if beat_this_checkpoint_ready(candidate):
                return candidate
    return None


def beat_this_checkpoint_ready(path: Path) -> bool:
    return (
        path.exists() and path.is_file() and path.stat().st_size >= BEAT_THIS_CHECKPOINT_MIN_BYTES
    )


def assert_beat_this_checkpoint_ready(path: Path) -> None:
    if not beat_this_checkpoint_ready(path):
        raise FileNotFoundError(f"Beat This final0 checkpoint is missing or incomplete: {path}")


def download_file(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_suffix(destination.suffix + ".download")
    if tmp.exists():
        tmp.unlink()
    request = urllib.request.Request(url, headers={"User-Agent": "FH Radio Studio release builder"})
    with urllib.request.urlopen(request, timeout=120) as response, tmp.open("wb") as out:
        shutil.copyfileobj(response, out)
    tmp.replace(destination)


def write_release_ai_models_manifest(
    destination: Path,
    checkpoint: Path,
    source: Path | None,
) -> None:
    manifest_path = destination / "ai_tools_manifest.json"
    manifest: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            manifest = {}
    manifest["release_bundled_models"] = {
        "beat_this": {
            "checkpoint": "final0",
            "relative_path": BEAT_THIS_CHECKPOINT_RELATIVE.as_posix(),
            "size": checkpoint.stat().st_size,
            "sha256": sha256_file(checkpoint),
            "source": str(source) if source is not None else BEAT_THIS_CHECKPOINT_URL,
            "prepared_at": datetime.now(timezone.utc).isoformat(),
        }
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def newest_wheel(wheel_dir: Path, package_name: str, version: str) -> Path:
    prefix = f"{normalize_wheel_name(package_name)}-{version}-"
    wheels = sorted(
        (path for path in wheel_dir.glob("*.whl") if path.name.startswith(prefix)),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not wheels:
        raise FileNotFoundError(f"No wheel matching {prefix}*.whl in {wheel_dir}")
    return wheels[0]


def normalize_wheel_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "_", name).strip("_")


def runtime_python_requirement(python: str) -> str:
    match = re.match(r"^(\d+)\.(\d+)", python.strip())
    if match is None:
        raise ValueError(f"Expected a major.minor Python version, got: {python!r}")
    major = int(match.group(1))
    minor = int(match.group(2))
    return f">={major}.{minor},<{major}.{minor + 1}"


def write_runtime_pyproject(
    path: Path,
    root_pyproject: dict[str, Any],
    wheel_name: str,
    python: str,
) -> None:
    project = root_pyproject["project"]
    tool = root_pyproject.get("tool", {})
    root_uv = tool.get("uv", {})
    sources = runtime_uv_sources(root_uv, wheel_name)
    dependency_groups = {
        name: deps
        for name, deps in root_pyproject.get("dependency-groups", {}).items()
        if name != "dev"
    }

    lines: list[str] = []
    lines.extend(
        [
            "[project]",
            f"name = {toml_value(RUNTIME_PROJECT_NAME)}",
            f"version = {toml_value(project['version'])}",
            f"requires-python = {toml_value(runtime_python_requirement(python))}",
        ]
    )
    write_array(lines, "dependencies", [f"{PACKAGE_NAME}=={project['version']}"])
    lines.append("")

    optional_dependencies = project.get("optional-dependencies", {})
    if optional_dependencies:
        lines.append("[project.optional-dependencies]")
        for name, deps in optional_dependencies.items():
            write_array(lines, toml_key(name), deps)
        lines.append("")

    if dependency_groups:
        lines.append("[dependency-groups]")
        for name, deps in dependency_groups.items():
            write_array(lines, toml_key(name), deps)
        lines.append("")

    lines.append("[tool.uv]")
    lines.append("package = false")
    if "conflicts" in root_uv:
        lines.append(f"conflicts = {toml_value(root_uv['conflicts'])}")
    lines.append("")

    if sources:
        lines.append("[tool.uv.sources]")
        for name, source in sources.items():
            lines.append(f"{toml_key(name)} = {toml_value(source)}")
        lines.append("")

    for index in root_uv.get("index", []):
        lines.append("[[tool.uv.index]]")
        for key, value in index.items():
            lines.append(f"{toml_key(key)} = {toml_value(value)}")
        lines.append("")

    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def runtime_uv_sources(root_uv: dict[str, Any], wheel_name: str) -> dict[str, Any]:
    sources = dict(root_uv.get("sources", {}))
    sources[PACKAGE_NAME] = {"path": f"wheels/{wheel_name}"}
    return sources


def toml_key(key: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]+", key):
        return key
    return json.dumps(key, ensure_ascii=False)


def write_array(lines: list[str], key: str, values: list[Any]) -> None:
    lines.append(f"{key} = [")
    for value in values:
        lines.append(f"  {toml_value(value)},")
    lines.append("]")


def toml_value(value: Any) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int | float):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return (
            "{ "
            + ", ".join(f"{toml_key(str(key))} = {toml_value(item)}" for key, item in value.items())
            + " }"
        )
    raise TypeError(f"Unsupported TOML value: {value!r}")


def copy_uv(uv_exe: str, repo_root: Path) -> None:
    uv_path = shutil.which(uv_exe) if not Path(uv_exe).is_file() else uv_exe
    if uv_path is None:
        print(f"warning: uv executable not found for copy: {uv_exe}", file=sys.stderr)
        return

    if sys.platform == "win32":
        platform_dir = "windows"
        executable_name = "uv.exe"
    elif sys.platform == "darwin":
        platform_dir = "macos"
        executable_name = "uv"
    else:
        platform_dir = "linux"
        executable_name = "uv"

    output = (
        repo_root
        / ".fh-radio-studio-dev"
        / "release-inputs"
        / "uv"
        / platform_dir
        / executable_name
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(uv_path, output)
    print(f"Copied uv: {output}")


if __name__ == "__main__":
    raise SystemExit(main())
