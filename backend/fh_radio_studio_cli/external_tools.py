from __future__ import annotations

import time

from .common import *


def _log(message: str = "") -> None:
    print(message, flush=True)


def _format_bytes(size: int) -> str:
    units = ("B", "KiB", "MiB", "GiB")
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"


def _response_size(response: object) -> Optional[int]:
    headers = getattr(response, "headers", None)
    if headers is None:
        return None
    raw = headers.get("Content-Length")
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _copy_with_progress(response: object, destination, label: str) -> int:
    total = _response_size(response)
    copied = 0
    next_percent = 10
    next_bytes = 8 * 1024 * 1024
    last_log = time.monotonic()
    if total:
        _log(f"    size {label}: {_format_bytes(total)}")
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        destination.write(chunk)
        copied += len(chunk)
        now = time.monotonic()
        if total:
            percent = int((copied / total) * 100)
            if percent >= next_percent or copied == total or now - last_log >= 4:
                _log(
                    f"    progress {label}: {percent}% "
                    f"({_format_bytes(copied)} / {_format_bytes(total)})"
                )
                next_percent = min(100, percent + 10)
                last_log = now
        elif copied >= next_bytes or now - last_log >= 4:
            _log(f"    progress {label}: {_format_bytes(copied)}")
            next_bytes = copied + 8 * 1024 * 1024
            last_log = now
    return copied


def _normalize_sha256(value: str) -> str:
    value = value.strip().lower()
    if value.startswith("sha256:"):
        value = value.removeprefix("sha256:")
    return value


def _verify_sha256(path: Path, expected_sha256: str, label: str) -> None:
    expected = _normalize_sha256(expected_sha256)
    actual = sha256_file(path)
    if actual != expected:
        die(f"{label} checksum mismatch: expected sha256 {expected}, " f"got {actual or 'missing'}")
    _log(f"    sha256 {actual}")


def find_executable(explicit: Optional[str], name: str) -> Optional[str]:
    if explicit:
        path = Path(explicit).expanduser()
        if path.exists():
            return str(path)
        die(f"{name} not found at {path}")

    for candidate in vendored_tool_candidates(name):
        if candidate.exists():
            return str(candidate)

    return shutil.which(name)


def collect_tool_status() -> Tuple[Dict[str, Dict[str, object]], bool]:
    tools: Dict[str, Dict[str, object]] = {}
    for name in ("ffmpeg", "vgmstream-cli", "fsbankcl"):
        found = find_vendored_executable(name)
        probe = _probe_tool(name, found)
        tools[name] = {
            "ok": bool(found) and bool(probe["ok"]),
            "path": str(Path(found).resolve()) if found else None,
            "version": probe["version"],
            "error": probe["error"],
        }
    return tools, all(bool(info["ok"]) for info in tools.values())


def find_vendored_executable(name: str) -> Optional[str]:
    for candidate in vendored_tool_candidates(name):
        if candidate.exists():
            return str(candidate)
    return None


def vendored_tool_candidates(name: str) -> List[Path]:
    lower = name.lower()
    if lower in ("ffmpeg", "ffmpeg.exe"):
        return [
            VENDORED_TOOLS_DIR / "ffmpeg" / "ffmpeg.exe",
            VENDORED_TOOLS_DIR / "ffmpeg.exe",
        ]
    if lower in ("vgmstream-cli", "vgmstream-cli.exe"):
        direct = [
            VENDORED_TOOLS_DIR / "vgmstream" / "vgmstream-cli.exe",
            VENDORED_TOOLS_DIR / "vgmstream-cli.exe",
        ]
        if (VENDORED_TOOLS_DIR / "vgmstream").exists():
            direct.extend(sorted((VENDORED_TOOLS_DIR / "vgmstream").rglob("vgmstream-cli.exe")))
        return direct
    if lower in ("fsbankcl", "fsbankcl.exe"):
        return [
            VENDORED_TOOLS_DIR / "fmod" / "fsbankcl.exe",
            VENDORED_TOOLS_DIR / "fsbankcl.exe",
        ]
    return []


def _probe_tool(name: str, executable: Optional[str]) -> Dict[str, object]:
    if not executable:
        return {"ok": False, "version": None, "error": "missing"}
    path = Path(executable)
    if not path.exists():
        return {"ok": False, "version": None, "error": "missing"}
    lower = name.lower()
    if lower == "ffmpeg":
        args = ["-version"]
        markers = ("ffmpeg version",)
    elif lower == "vgmstream-cli":
        args = ["-h"]
        markers = ("vgmstream cli decoder",)
    elif lower == "fsbankcl":
        args = ["-help"]
        markers = ("fmod soundbank generator",)
    else:
        args = ["--help"]
        markers = ()
    try:
        result = subprocess.run(
            [str(path), *args],
            cwd=path.parent,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=8,
            check=False,
        )
    except Exception as exc:
        return {
            "ok": False,
            "version": None,
            "error": f"{type(exc).__name__}: {exc}",
        }
    text = "\n".join(
        part.strip() for part in (result.stdout, result.stderr) if part and part.strip()
    )
    first_line = text.splitlines()[0] if text else None
    matched = any(marker in text.lower() for marker in markers)
    ok = result.returncode == 0 or matched
    return {
        "ok": ok,
        "version": first_line,
        "error": None if ok else f"exit {result.returncode}",
    }


def download_file(
    url: str,
    destination: Path,
    force: bool = False,
    label: Optional[str] = None,
    sha256: Optional[str] = None,
) -> None:
    label = label or destination.name
    if destination.exists() and not force:
        if sha256:
            actual = sha256_file(destination)
            if actual == _normalize_sha256(sha256):
                _log(f"  [skip] {label}: already exists and is verified")
                _log(f"    path {destination}")
                _log(f"    sha256 {actual}")
                return
            _log(f"  [repair] {label}: existing file failed checksum")
            _log(f"    path {destination}")
            _log(f"    expected sha256 {_normalize_sha256(sha256)}")
            _log(f"    actual sha256 {actual or 'missing'}")
        else:
            _log(f"  [skip] {label}: already exists at {destination}")
            return
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_suffix(destination.suffix + ".download")
    _log(f"  [download] {label}")
    _log(f"    source {url}")
    _log(f"    staging {tmp}")
    try:
        with urllib.request.urlopen(url) as response, tmp.open("wb") as fh:
            copied = _copy_with_progress(response, fh, label)
        if sha256:
            _verify_sha256(tmp, sha256, label)
        tmp.replace(destination)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    _log(f"    saved {destination} ({_format_bytes(copied)})")


def install_ffmpeg(tools_dir: Path, force: bool = False) -> Path:
    ffmpeg_path = tools_dir / "ffmpeg" / "ffmpeg.exe"
    _log("[ffmpeg] target")
    _log(f"  version {FFMPEG_VERSION}")
    _log(f"  exe {ffmpeg_path}")
    if ffmpeg_path.exists() and not force:
        probe = _probe_tool("ffmpeg", str(ffmpeg_path))
        if probe["ok"]:
            _log(f"  [skip] ffmpeg already installed: {ffmpeg_path}")
            return ffmpeg_path
        _log(f"  [repair] ffmpeg exists but failed probe: {probe['error']}")
    with tempfile.TemporaryDirectory() as tmp_dir:
        _log(f"  temp {tmp_dir}")
        archive = Path(tmp_dir) / "ffmpeg.zip"
        download_file(
            FFMPEG_URL,
            archive,
            force=True,
            label="ffmpeg archive",
            sha256=FFMPEG_SHA256,
        )
        _log("  [extract] locating ffmpeg.exe in archive")
        with zipfile.ZipFile(archive) as zf:
            members = [name for name in zf.namelist() if name.endswith("/bin/ffmpeg.exe")]
            if not members:
                die("ffmpeg.exe not found in downloaded archive")
            member = members[0]
            _log(f"    member {member}")
            ffmpeg_path.parent.mkdir(parents=True, exist_ok=True)
            _log(f"    writing {ffmpeg_path}")
            with zf.open(member) as src, ffmpeg_path.open("wb") as dst:
                shutil.copyfileobj(src, dst)
    _log(f"  [ready] ffmpeg -> {ffmpeg_path} ({_format_bytes(ffmpeg_path.stat().st_size)})")
    return ffmpeg_path


def install_vgmstream(tools_dir: Path, force: bool = False) -> Path:
    vgm_dir = tools_dir / "vgmstream"
    _log("[vgmstream] target")
    _log(f"  version {VGMSTREAM_VERSION}")
    _log(f"  dir {vgm_dir}")
    existing = (
        find_executable(str(vgm_dir / "vgmstream-cli.exe"), "vgmstream-cli")
        if (vgm_dir / "vgmstream-cli.exe").exists()
        else None
    )
    if existing and not force:
        probe = _probe_tool("vgmstream-cli", existing)
        if probe["ok"]:
            _log(f"  [skip] vgmstream-cli already installed: {existing}")
            return Path(existing)
        _log(f"  [repair] vgmstream-cli exists but failed probe: {probe['error']}")
        shutil.rmtree(vgm_dir)
    if vgm_dir.exists() and force:
        _log(f"  [clean] removing existing directory {vgm_dir}")
        shutil.rmtree(vgm_dir)
    vgm_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp_dir:
        _log(f"  temp {tmp_dir}")
        archive = Path(tmp_dir) / "vgmstream.zip"
        download_file(
            VGMSTREAM_URL,
            archive,
            force=True,
            label="vgmstream archive",
            sha256=VGMSTREAM_SHA256,
        )
        with zipfile.ZipFile(archive) as zf:
            members = zf.namelist()
            _log(f"  [extract] {len(members)} entries -> {vgm_dir}")
            zf.extractall(vgm_dir)
    hits = sorted(vgm_dir.rglob("vgmstream-cli.exe"))
    if not hits:
        die("vgmstream-cli.exe not found in downloaded archive")
    _log(f"  [ready] vgmstream-cli -> {hits[0]}")
    return hits[0]


def install_fmod_bundle(tools_dir: Path, force: bool = False) -> Path:
    fmod_dir = tools_dir / "fmod"
    fmod_dir.mkdir(parents=True, exist_ok=True)
    _log("[fmod] target")
    _log(f"  version {FMOD_BUNDLE_VERSION}")
    _log(f"  dir {fmod_dir}")
    _log(f"  files {len(FMOD_BUNDLE_FILES)}")
    for index, filename in enumerate(FMOD_BUNDLE_FILES, start=1):
        _log(f"  [{index}/{len(FMOD_BUNDLE_FILES)}] {filename}")
        download_file(
            FMOD_BUNDLE_BASE + filename,
            fmod_dir / filename,
            force=force,
            label=f"fmod/{filename}",
            sha256=FMOD_BUNDLE_SHA256.get(filename),
        )
    fsbankcl = fmod_dir / "fsbankcl.exe"
    if not fsbankcl.exists():
        die("fsbankcl.exe was not installed")
    _log(f"  [ready] fsbankcl -> {fsbankcl}")
    return fsbankcl


def cmd_check_tools(_: argparse.Namespace) -> int:
    tools, _tools_ok = collect_tool_status()
    _log("External tool check:")
    for tool, info in tools.items():
        _log(f"  {tool:<14} {info['path'] or 'missing'}")
    _log()
    _log(
        "prepare-track can run without these for WAV/FLAC files. build-package needs fsbankcl unless --skip-bank is used."
    )
    return 0


def cmd_install_tools(args: argparse.Namespace) -> int:
    tools_dir = Path(args.tools_dir).expanduser() if args.tools_dir else VENDORED_TOOLS_DIR
    tools_dir.mkdir(parents=True, exist_ok=True)
    installed: Dict[str, str] = {}

    _log("== Install FH Radio Studio audio tools ==")
    _log(f"Toolchain audio dir : {tools_dir.resolve()}")
    _log(f"Force Reinstall     : {str(bool(args.force)).lower()}")
    selected_components = [
        name
        for name, skipped in (
            ("ffmpeg", args.skip_ffmpeg),
            ("vgmstream-cli", args.skip_vgmstream),
            ("FMOD/FSBank", args.skip_fmod),
        )
        if not skipped
    ]
    _log(
        "Selected components : "
        + (", ".join(selected_components) if selected_components else "none")
    )
    if not args.skip_ffmpeg:
        installed["ffmpeg"] = str(install_ffmpeg(tools_dir, force=args.force).resolve())
    if not args.skip_vgmstream:
        installed["vgmstream-cli"] = str(install_vgmstream(tools_dir, force=args.force).resolve())
    if not args.skip_fmod:
        installed["fsbankcl"] = str(install_fmod_bundle(tools_dir, force=args.force).resolve())

    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "tools_dir": str(tools_dir.resolve()),
        "installed": installed,
        "sources": {
            "ffmpeg": {
                "version": FFMPEG_VERSION,
                "url": FFMPEG_URL,
                "sha256": FFMPEG_SHA256,
            },
            "vgmstream": {
                "version": VGMSTREAM_VERSION,
                "url": VGMSTREAM_URL,
                "sha256": VGMSTREAM_SHA256,
            },
            "fmod_bundle": {
                "version": FMOD_BUNDLE_VERSION,
                "commit": FMOD_BUNDLE_COMMIT,
                "base_url": FMOD_BUNDLE_BASE,
                "files": {
                    filename: {
                        "url": FMOD_BUNDLE_BASE + filename,
                        "sha256": FMOD_BUNDLE_SHA256.get(filename),
                    }
                    for filename in FMOD_BUNDLE_FILES
                },
            },
        },
        "notes": [
            "ffmpeg and vgmstream are public third-party tools.",
            "fsbankcl is part of the FMOD/FSBank toolchain; this installer records the mirror source used.",
        ],
    }
    write_json(tools_dir / "audio_tools_manifest.json", manifest)
    _log()
    _log("Installed:")
    for name, path in installed.items():
        _log(f"  {name:<14} {path}")
    _log(f"Manifest: {tools_dir / 'audio_tools_manifest.json'}")
    return 0
