from __future__ import annotations

from .audio import linear_resample
from .common import *
from .loudness import LOUDNESS_ALGORITHM_VERSION, analyze_loudness_file
from .metadata import (
    AUDIO_SUFFIXES,
    has_import_completion_marker,
    metadata_cache_path,
    upsert_track_metadata_cache_entry,
    write_import_completion_marker,
    write_track_metadata_tags,
)

LOSSLESS_PROJECT_EXTENSIONS = {".wav", ".flac", ".aif", ".aiff"}


def cmd_import_audio(args: argparse.Namespace) -> int:
    project_dir = Path(args.project_dir).expanduser().resolve()
    source_dir = project_dir / args.target_folder
    source_dir.mkdir(parents=True, exist_ok=True)

    files = collect_import_audio_files(Path(value) for value in args.inputs)
    if not files:
        die("No importable audio files found")

    cache_path = metadata_cache_path(project_dir)
    imported = []
    for file in files:
        item = import_audio_file(
            file,
            source_dir,
            ffmpeg=args.ffmpeg,
            title=args.title,
            artist=args.artist,
            album=args.album,
            cover_image=Path(args.cover_image).expanduser() if args.cover_image else None,
            require_completion_marker=args.target_folder == "sources",
        )
        dst = Path(str(item["path"]))
        loudness_analysis = _try_analyze_import_loudness(dst, ffmpeg=args.ffmpeg)
        item["loudness_analysis"] = loudness_analysis
        upsert_track_metadata_cache_entry(
            cache_path,
            dst,
            loudness_analysis=loudness_analysis,
        )
        imported.append(item)
    summary = {
        "schema_version": 1,
        "project_dir": str(project_dir),
        "sources_dir": str(source_dir),
        "target_folder": args.target_folder,
        "target_dir": str(source_dir),
        "imported": imported,
        "changed": [item for item in imported if item["action"] == "transcoded"],
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False))
    else:
        for item in imported:
            print(
                f"{item['action']}: {item['source']} -> {item['path']} "
                f"({item.get('source_sample_rate') or 'unknown'} Hz -> {item['sample_rate']} Hz)"
            )
    return 0


def collect_import_audio_files(inputs: Iterable[Path]) -> List[Path]:
    files: List[Path] = []
    seen: set[str] = set()
    for raw in inputs:
        path = raw.expanduser()
        if path.is_file():
            if _is_audio_path(path) and path_key(path) not in seen:
                seen.add(path_key(path))
                files.append(path.resolve())
            continue
        if not path.is_dir():
            continue
        children = sorted(
            (item for item in path.iterdir() if item.is_file() and _is_audio_path(item)),
            key=lambda item: str(item).casefold(),
        )
        for child in children:
            key = path_key(child)
            if key in seen:
                continue
            seen.add(key)
            files.append(child.resolve())
    return files


def import_audio_file(
    src: Path,
    source_dir: Path,
    *,
    ffmpeg: Optional[str],
    title: Optional[str] = None,
    artist: Optional[str] = None,
    album: Optional[str] = None,
    cover_image: Optional[Path] = None,
    require_completion_marker: bool = False,
) -> Dict[str, object]:
    info = _audio_info(src)
    source_sample_rate = int(info.samplerate) if info is not None and info.samplerate else None
    needs_transcode = source_sample_rate != TARGET_SAMPLE_RATE
    src_inside_sources = _is_inside(src, source_dir)

    if not needs_transcode:
        if src_inside_sources:
            dst = src.resolve()
            action = "kept"
            out_info = _audio_info(dst)
            tags_written = _write_import_tags(
                dst,
                title=title,
                artist=artist,
                album=album,
                cover_image=cover_image,
            )
        else:
            dst = _unique_destination(source_dir, src.name)
            out_info, tags_written = _copy_to_project(
                src,
                dst,
                require_completion_marker=require_completion_marker,
                title=title,
                artist=artist,
                album=album,
                cover_image=cover_image,
            )
            action = "copied"
        return _result(src, dst, action, source_sample_rate, out_info, tags_written)

    dst_name = _transcoded_basename(src)
    if src_inside_sources and dst_name == src.name:
        dst = src.resolve()
    else:
        dst = _unique_destination(source_dir, dst_name)
    out_info, tags_written = _transcode_to_48k(
        src,
        dst,
        ffmpeg=ffmpeg,
        require_completion_marker=require_completion_marker,
        title=title,
        artist=artist,
        album=album,
        cover_image=cover_image,
    )
    return _result(src, dst, "transcoded", source_sample_rate, out_info, tags_written)


def _result(
    src: Path,
    dst: Path,
    action: str,
    source_sample_rate: Optional[int],
    out_info: object,
    tags_written: bool,
) -> Dict[str, object]:
    return {
        "source": str(src.resolve()),
        "path": str(dst.resolve()),
        "action": action,
        "source_sample_rate": source_sample_rate,
        "sample_rate": int(getattr(out_info, "samplerate", 0) or TARGET_SAMPLE_RATE),
        "channels": int(getattr(out_info, "channels", 0) or 0),
        "samples": int(getattr(out_info, "frames", 0) or 0),
        "metadata_tags_written": tags_written,
    }


def _write_import_tags(
    dst: Path,
    *,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover_image: Optional[Path],
) -> bool:
    return write_track_metadata_tags(
        dst,
        title=title,
        artist=artist,
        album=album,
        cover_image=cover_image,
    )


def _transcoded_basename(src: Path) -> str:
    suffix = src.suffix.lower()
    if suffix in LOSSLESS_PROJECT_EXTENSIONS:
        return src.name
    return f"{src.stem}.wav"


def _transcode_to_48k(
    src: Path,
    dst: Path,
    *,
    ffmpeg: Optional[str],
    require_completion_marker: bool,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover_image: Optional[Path],
) -> Tuple[object, bool]:
    tmp = _temp_output_path(dst)
    try:
        if ffmpeg:
            try:
                _ffmpeg_transcode(src, tmp, ffmpeg)
                return _finish_project_audio(
                    tmp,
                    dst,
                    require_completion_marker=require_completion_marker,
                    title=title,
                    artist=artist,
                    album=album,
                    cover_image=cover_image,
                )
            except CliError:
                if tmp.exists():
                    tmp.unlink()
        try:
            data, sample_rate = sf.read(str(src), dtype="float32", always_2d=True)
            if sample_rate != TARGET_SAMPLE_RATE:
                data = linear_resample(data, sample_rate, TARGET_SAMPLE_RATE)
            data = _to_stereo(data)
            _write_project_audio(tmp, data, dst.suffix.lower())
        except Exception as exc:
            if not ffmpeg:
                die(
                    f"Could not transcode {src} with libsndfile ({exc}). Pass --ffmpeg for this format."
                )
            _ffmpeg_transcode(src, tmp, ffmpeg)
        return _finish_project_audio(
            tmp,
            dst,
            require_completion_marker=require_completion_marker,
            title=title,
            artist=artist,
            album=album,
            cover_image=cover_image,
        )
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def _copy_to_project(
    src: Path,
    dst: Path,
    *,
    require_completion_marker: bool,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover_image: Optional[Path],
) -> Tuple[object, bool]:
    tmp = _temp_output_path(dst)
    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        if tmp.exists():
            tmp.unlink()
        shutil.copy2(src, tmp)
        return _finish_project_audio(
            tmp,
            dst,
            require_completion_marker=require_completion_marker,
            title=title,
            artist=artist,
            album=album,
            cover_image=cover_image,
        )
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass


def _finish_project_audio(
    tmp: Path,
    dst: Path,
    *,
    require_completion_marker: bool,
    title: Optional[str],
    artist: Optional[str],
    album: Optional[str],
    cover_image: Optional[Path],
) -> Tuple[object, bool]:
    tags_written = _write_import_tags(
        tmp,
        title=title,
        artist=artist,
        album=album,
        cover_image=cover_image,
    )
    if require_completion_marker:
        marker_written = write_import_completion_marker(tmp)
        if not marker_written or not has_import_completion_marker(tmp):
            die(f"Could not verify completed manual import marker for: {dst.name}")
    out_info = _audio_info(tmp)
    if out_info is None:
        die(f"Imported audio became unreadable before finalizing: {dst.name}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(tmp, dst)
    return out_info, tags_written


def _write_project_audio(dst: Path, data: np.ndarray, suffix: str) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if suffix == ".flac":
        sf.write(str(dst), data, TARGET_SAMPLE_RATE, format="FLAC", subtype="PCM_24")
    elif suffix in {".aif", ".aiff"}:
        sf.write(str(dst), data, TARGET_SAMPLE_RATE, format="AIFF", subtype="PCM_16")
    else:
        sf.write(str(dst), data, TARGET_SAMPLE_RATE, format="WAV", subtype="PCM_16")


def _ffmpeg_transcode(src: Path, dst: Path, ffmpeg: str) -> None:
    cmd = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(src),
        "-ac",
        "2",
        "-ar",
        str(TARGET_SAMPLE_RATE),
        "-sample_fmt",
        "s16",
        str(dst),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0 or not dst.exists():
        die(f"ffmpeg failed for {src}:\n{result.stderr[-2000:]}")


def _to_stereo(data: np.ndarray) -> np.ndarray:
    if data.ndim == 1:
        data = data[:, np.newaxis]
    if data.shape[1] == 1:
        return np.repeat(data, 2, axis=1)
    if data.shape[1] == 2:
        return data
    return data[:, :2]


def _audio_info(path: Path) -> object:
    try:
        return sf.info(str(path))
    except Exception:
        return None


def _temp_output_path(dst: Path) -> Path:
    return dst.with_name(f".{dst.stem}.fh-radio-studio-import-tmp{dst.suffix}")


def _unique_destination(directory: Path, basename: str) -> Path:
    safe_base = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", basename)
    suffix = Path(safe_base).suffix
    stem = Path(safe_base).stem.strip() or "track"
    candidate = directory / f"{stem}{suffix}"
    index = 2
    while candidate.exists():
        candidate = directory / f"{stem}-{index}{suffix}"
        index += 1
    return candidate


def _is_inside(child: Path, parent: Path) -> bool:
    try:
        child_path = child.resolve()
        parent_path = parent.resolve()
        return child_path == parent_path or parent_path in child_path.parents
    except OSError:
        child_text = str(child.absolute()).casefold()
        parent_text = str(parent.absolute()).casefold()
        return child_text == parent_text or child_text.startswith(parent_text + os.sep)


def _is_audio_path(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_SUFFIXES


def _try_analyze_import_loudness(dst: Path, *, ffmpeg: Optional[str]) -> Dict[str, object]:
    try:
        return analyze_loudness_file(dst, ffmpeg=ffmpeg)
    except Exception as exc:
        return {
            "status": "error",
            "algorithm_version": LOUDNESS_ALGORITHM_VERSION,
            "error": f"loudness_cache_failed:{type(exc).__name__}",
            "warnings": [str(exc)],
        }
