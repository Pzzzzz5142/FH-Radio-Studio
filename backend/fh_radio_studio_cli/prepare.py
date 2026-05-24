from __future__ import annotations

from .ai_timepoints.providers.baseline_mir import estimate_timing
from .audio import build_markers
from .common import *
from .external_tools import find_executable
from .loudness import (
    analyze_loudness_file,
    build_custom_set_loudness_profile,
    ensure_baseline_loudness_envelope,
    prepare_loudness_matched_audio,
)
from .radio_xml import build_sample_element, element_to_string


def cmd_prepare_track(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser()
    if not input_path.exists():
        die(f"Input audio not found: {input_path}")

    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    artist = args.artist
    title = args.title or input_path.stem
    sound_name = args.sound_name or make_sound_name(args.radio, artist, title)
    out_wav = out_dir / make_wav_filename(sound_name)

    print(f"Reading: {input_path}")
    ffmpeg = find_executable(args.ffmpeg, "ffmpeg") if args.ffmpeg else None
    loudness_analysis = analyze_loudness_file(input_path, ffmpeg=ffmpeg)
    if loudness_analysis.get("status") != "ok":
        die(f"Could not measure loudness for {input_path}: {loudness_analysis.get('error')}")
    loudness_profile = build_custom_set_loudness_profile(
        [loudness_analysis],
        ensure_baseline_loudness_envelope(None),
        radio=args.radio,
    )
    before, after, loudness = prepare_loudness_matched_audio(
        input_path,
        out_wav,
        loudness_profile,
        ffmpeg=ffmpeg,
        input_analysis=loudness_analysis,
    )
    if before.get("sample_rate") and before["sample_rate"] != TARGET_SAMPLE_RATE:
        print(f"Resampled {before['sample_rate']} Hz -> {TARGET_SAMPLE_RATE} Hz")
    data, sr = sf.read(str(out_wav), dtype="float32", always_2d=True)

    timing = estimate_timing(data, sr, bpm=args.bpm)
    markers = build_markers(args, timing, int(after["samples"]), int(after["sample_rate"]))

    manifest = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "game": "FH6",
        "radio": args.radio,
        "target_bank": args.bank or f"R{args.radio}_Tracks_CU1",
        "sound_name": sound_name,
        "display_name": title,
        "artist": artist,
        "sample_rate": sr,
        "sample_length": int(after["samples"]),
        "markers": markers,
        "loops": [
            {"Name": loop_name, "StartMarker": start, "EndMarker": end}
            for loop_name, start, end in LOOPS
        ],
        "bpm": [{"Value": str(args.bpm), "Start": "-1"}],
        "audio": {
            "source": str(input_path.resolve()),
            "wav": str(out_wav.resolve()),
            "before": before,
            "after": after,
            "loudness_profile": loudness_profile,
            "loudness": loudness,
        },
    }

    sample_xml = element_to_string(build_sample_element(manifest))
    manifest_path = out_dir / "manifest.json"
    sample_path = out_dir / "radioinfo_sample.xml"
    summary_path = out_dir / "summary.txt"
    write_json(manifest_path, manifest)
    write_text(sample_path, sample_xml + "\n")
    write_text(
        summary_path,
        "\n".join(
            [
                "FH Radio Studio CLI prepare-track",
                "=" * 36,
                f"Input        : {input_path.resolve()}",
                f"Output WAV   : {out_wav.resolve()}",
                f"Manifest     : {manifest_path.resolve()}",
                f"Sample XML   : {sample_path.resolve()}",
                f"Radio        : R{args.radio}",
                f"Target bank  : {manifest['target_bank']}",
                f"SoundName    : {sound_name}",
                f"Display      : {artist} - {title}",
                f"SampleLength : {after['samples']}",
                "",
                "Markers:",
                *[
                    f"  {name:<18} {markers[name]:>10}  {s2tc(markers[name], sr) if markers[name] >= 0 else '-'}"
                    for name in MARKER_ORDER
                    if name
                    in (
                        "TrackDrop",
                        "PostDrop",
                        "TrackLoopStart",
                        "TrackLoopEnd",
                        "PostRaceLoopStart",
                        "PostRaceLoopEnd",
                        "StingerStart",
                        "DJStart",
                        "End",
                    )
                ],
                "",
                "Next:",
                "  1. Rebuild the matching .assets.bank so it contains this WAV/sound.",
                "  2. Run patch-xml against this manifest and inspect the staged XML.",
            ]
        )
        + "\n",
    )

    print(f"WAV       : {out_wav}")
    print(f"Manifest  : {manifest_path}")
    print(f"Sample XML: {sample_path}")
    before_rms = before.get("rms_dbfs")
    before_rms_text = (
        f"{before_rms:.1f} dBFS" if isinstance(before_rms, (int, float)) else "unknown"
    )
    print(f"RMS       : {before_rms_text} -> {after['rms_dbfs']:.1f} dBFS")
    print("Markers:")
    for name in (
        "TrackDrop",
        "PostDrop",
        "TrackLoopStart",
        "TrackLoopEnd",
        "PostRaceLoopStart",
        "PostRaceLoopEnd",
        "StingerStart",
        "DJStart",
    ):
        print(f"  {name:<18} {markers[name]:>10}  {s2tc(markers[name], sr)}")
    return 0
