from __future__ import annotations

from .ai_timepoints.cli import PROFILES as AI_TIMEPOINT_PROFILES
from .ai_timepoints.cli import (
    cmd_analyze_audio,
    cmd_check_ai_tools,
    cmd_prepare_ai_cache,
)
from .baseline import cmd_baseline
from .common import *
from .deploy import cmd_deploy_package
from .external_tools import cmd_check_tools, cmd_install_tools
from .game import cmd_list_radios, cmd_probe
from .import_audio import cmd_import_audio
from .inspect_bank import cmd_inspect_bank
from .integrity import cmd_verify_integrity
from .language import cmd_language_swap
from .loudness import (
    DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU,
    MAX_CUSTOM_LOUDNESS_OFFSET_LU,
    MIN_CUSTOM_LOUDNESS_OFFSET_LU,
)
from .metadata import cmd_scan_metadata
from .package import cmd_build_package
from .prepare import cmd_prepare_track
from .radio_xml import cmd_patch_xml
from .reconstruct_plan import cmd_reconstruct_plan
from .status import cmd_status
from .toolchain import PROFILES as TOOLCHAIN_PROFILES
from .toolchain import cmd_toolchain_status


def add_audio_analysis_args(parser: argparse.ArgumentParser, *, default_profile: str) -> None:
    parser.add_argument("input", help="Input audio file")
    parser.add_argument("--profile", choices=AI_TIMEPOINT_PROFILES, default=default_profile)
    parser.add_argument("--model-dir", help="AI model cache directory")
    parser.add_argument("--bins", type=int, default=512, help="Number of waveform bins")
    parser.add_argument(
        "--bpm",
        type=float,
        default=120.0,
        help="Fallback BPM until deep beat detection is installed",
    )
    parser.add_argument("--max-beats", type=int, default=800)
    parser.add_argument(
        "--ffmpeg", help="Optional ffmpeg executable for formats libsndfile cannot read"
    )
    parser.add_argument("--json", action="store_true", help="Print JSON only")
    parser.add_argument(
        "--progress-jsonl",
        action="store_true",
        help="Emit structured progress events to stderr as prefixed JSON lines",
    )


def add_common_game_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--game-dir",
        help="FH6 install root, or the media/audio folder. Defaults to FH6_GAME_DIR or Steam path.",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FH Radio Studio staging CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    probe = sub.add_parser(
        "probe", help="Validate game/audio directory and summarize FH6 radio files"
    )
    add_common_game_arg(probe)
    probe.set_defaults(func=cmd_probe)

    list_radios = sub.add_parser("list-radios", help="List radio stations and optionally tracks")
    add_common_game_arg(list_radios)
    list_radios.add_argument("--radio-info", help="Path to one RadioInfo_*.xml file")
    list_radios.add_argument("--radio", type=int, help="Only show one radio number")
    list_radios.add_argument(
        "--tracks", action="store_true", help="Also print track SoundName entries"
    )
    list_radios.set_defaults(func=cmd_list_radios)

    status = sub.add_parser("status", help="Emit structured dashboard status")
    add_common_game_arg(status)
    status.add_argument(
        "--radio", type=int, default=4, help="Target radio number for selected_radio"
    )
    status.add_argument("--source", help="Text language expected for display")
    status.add_argument("--target", help="Voice language slot expected to be active")
    status.add_argument(
        "--baseline-manifest",
        help="Pristine baseline manifest used to verify original language slots",
    )
    status.add_argument("--preferred-path", help="Override the UserPreferredLang file path")
    status.add_argument("--json", action="store_true", help="Print JSON only")
    status.set_defaults(func=cmd_status)

    verify_integrity = sub.add_parser(
        "verify-integrity", help="Verify game files against package and baselines"
    )
    add_common_game_arg(verify_integrity)
    verify_integrity.add_argument(
        "--package-dir", help="Optional package directory used for package/applied checks"
    )
    verify_integrity.add_argument("--baseline-manifest", help="Current pristine baseline manifest")
    verify_integrity.add_argument(
        "--pending-baseline-manifest", help="Pending-verify baseline manifest"
    )
    verify_integrity.add_argument(
        "--last-applied-package-manifest",
        help="Last successfully deployed package fingerprint manifest",
    )
    verify_integrity.add_argument(
        "--preferred-path", help="Override the UserPreferredLang file path"
    )
    verify_integrity.add_argument(
        "--jobs",
        type=int,
        default=0,
        help="Parallel MD5 worker count; default auto uses half of logical CPU cores for large plans",
    )
    verify_integrity.add_argument(
        "--progress-jsonl",
        action="store_true",
        help="Emit structured MD5 progress events to stderr",
    )
    verify_integrity.add_argument("--json", action="store_true", help="Print JSON only")
    verify_integrity.set_defaults(func=cmd_verify_integrity)

    tools = sub.add_parser(
        "check-tools", help="Check optional external tools for later bank rebuilds"
    )
    tools.set_defaults(func=cmd_check_tools)

    install_tools = sub.add_parser(
        "install-tools",
        help="Install self-contained audio tools under the active FH Radio Studio toolchain",
    )
    install_tools.add_argument("--tools-dir", help="Override install directory")
    install_tools.add_argument(
        "--force", action="store_true", help="Re-download/reinstall existing tools"
    )
    install_tools.add_argument("--skip-ffmpeg", action="store_true")
    install_tools.add_argument("--skip-vgmstream", action="store_true")
    install_tools.add_argument("--skip-fmod", action="store_true", help="Skip fsbankcl/FMOD bundle")
    install_tools.set_defaults(func=cmd_install_tools)

    toolchain = sub.add_parser(
        "toolchain-status", help="Emit structured uv/Python/audio/AI toolchain status"
    )
    toolchain.add_argument("--profile", choices=TOOLCHAIN_PROFILES, default="local-heavy")
    toolchain.add_argument("--model-dir", help="AI model cache directory")
    toolchain.add_argument("--json", action="store_true", help="Print JSON only")
    toolchain.set_defaults(func=cmd_toolchain_status)

    inspect = sub.add_parser(
        "inspect-bank", help="Inspect embedded FSB5 sample names in a .assets.bank"
    )
    add_common_game_arg(inspect)
    inspect.add_argument("bank", help="Path to a .assets.bank, or a bank name like R3_Tracks_CU1")
    inspect.add_argument(
        "--radio", type=int, default=3, help="Radio number used when bank is a name"
    )
    inspect.add_argument("--limit", type=int, default=80, help="Maximum samples to print")
    inspect.set_defaults(func=cmd_inspect_bank)

    prepare = sub.add_parser(
        "prepare-track", help="Prepare audio and generate an FH6 RadioInfo sample manifest"
    )
    prepare.add_argument(
        "input", help="Input audio file readable by libsndfile, such as FLAC or WAV"
    )
    prepare.add_argument("--out-dir", required=True, help="Output work directory")
    prepare.add_argument("--radio", type=int, required=True, help="Target FH6 radio number")
    prepare.add_argument("--bank", help="Target bank name; default R{radio}_Tracks_CU1")
    prepare.add_argument("--title", help="Display title; defaults to input filename stem")
    prepare.add_argument("--artist", default="Unknown Artist", help="Display artist")
    prepare.add_argument(
        "--sound-name", help="Internal SoundName. Must match the rebuilt bank plan."
    )
    prepare.add_argument("--gain-db", type=float, default=-15.0, help=argparse.SUPPRESS)
    prepare.add_argument(
        "--ffmpeg", help="Optional ffmpeg executable for formats libsndfile cannot read"
    )
    prepare.add_argument("--bpm", default="0", help="BPM value to write into the sample block")
    prepare.add_argument("--track-drop-sec", type=float)
    prepare.add_argument("--post-drop-sec", type=float)
    prepare.add_argument("--track-loop-start-sec", type=float)
    prepare.add_argument("--track-loop-end-sec", type=float)
    prepare.add_argument("--post-loop-start-sec", type=float)
    prepare.add_argument("--post-loop-end-sec", type=float)
    prepare.set_defaults(func=cmd_prepare_track)

    analyze = sub.add_parser(
        "analyze-audio", help="Analyze audio with the current AI contract; defaults to local-base"
    )
    add_audio_analysis_args(analyze, default_profile="local-base")
    analyze.set_defaults(func=cmd_analyze_audio)

    import_audio = sub.add_parser(
        "import-audio", help="Import audio into a project audio folder, transcoding non-48k files"
    )
    import_audio.add_argument("inputs", nargs="+", help="Audio files or directories to import")
    import_audio.add_argument(
        "--project-dir", required=True, help="FH Radio Studio project directory"
    )
    import_audio.add_argument(
        "--target-folder",
        choices=("sources", "siren"),
        default="sources",
        help="Project audio folder to receive imported files",
    )
    import_audio.add_argument("--title", help="Optional title tag to write to imported audio")
    import_audio.add_argument(
        "--artist", help="Optional artist/album artist tag to write to imported audio"
    )
    import_audio.add_argument("--album", help="Optional album tag to write to imported audio")
    import_audio.add_argument(
        "--cover-image", help="Optional image file to embed as imported audio cover art"
    )
    import_audio.add_argument(
        "--ffmpeg", help="Optional ffmpeg executable for formats libsndfile cannot transcode"
    )
    import_audio.add_argument("--json", action="store_true", help="Print JSON summary only")
    import_audio.set_defaults(func=cmd_import_audio)

    scan_metadata = sub.add_parser(
        "scan-metadata", help="Read audio tags and update the project track metadata cache"
    )
    scan_metadata.add_argument("inputs", nargs="*", help="Audio files or directories to scan")
    scan_metadata.add_argument(
        "--project-dir", required=True, help="FH Radio Studio project directory"
    )
    scan_metadata.add_argument(
        "--all-sources", action="store_true", help="Also scan the project sources folder"
    )
    scan_metadata.add_argument("--json", action="store_true", help="Print JSON summary only")
    scan_metadata.set_defaults(func=cmd_scan_metadata)

    reconstruct_plan = sub.add_parser(
        "reconstruct-plan",
        help="Diff the current game RadioInfo against the baseline and rebuild a playlist plan",
    )
    reconstruct_plan.add_argument(
        "--game-dir", help="FH6 game directory; auto-detected when omitted"
    )
    reconstruct_plan.add_argument(
        "--baseline-manifest", required=True, help="Trusted baseline manifest JSON"
    )
    reconstruct_plan.add_argument(
        "--metadata-cache", help="Project track_metadata.json used to resolve sources"
    )
    reconstruct_plan.add_argument(
        "--music-dir",
        action="append",
        default=[],
        help="Project music root (sources/siren); repeatable",
    )
    reconstruct_plan.add_argument("--source", help="Source display language (RadioInfo preference)")
    reconstruct_plan.add_argument("--target", help="Target voice language (RadioInfo preference)")
    reconstruct_plan.add_argument(
        "--out",
        required=True,
        help="Path to write the reconstructed playlist_plan.json, or '-' to emit it on stdout",
    )
    reconstruct_plan.set_defaults(func=cmd_reconstruct_plan)

    check_ai = sub.add_parser(
        "check-ai-tools", help="Check local AI timepoint provider/runtime readiness"
    )
    check_ai.add_argument("--profile", choices=AI_TIMEPOINT_PROFILES, default="local-heavy")
    check_ai.add_argument("--model-dir", help="AI model cache directory")
    check_ai.add_argument("--json", action="store_true", help="Print JSON only")
    check_ai.set_defaults(func=cmd_check_ai_tools)

    prepare_ai = sub.add_parser(
        "prepare-ai-cache",
        help="Prepare the local AI model cache/manifest",
    )
    prepare_ai.add_argument("--profile", choices=AI_TIMEPOINT_PROFILES, default="local-heavy")
    prepare_ai.add_argument("--model-dir", help="AI model cache directory")
    prepare_ai.add_argument(
        "--warmup-provider",
        action="append",
        choices=("beat_this", "mert", "songformer", "demucs"),
        help="Download/warm local model weights for this provider into --model-dir",
    )
    prepare_ai.add_argument("--json", action="store_true", help="Print JSON only")
    prepare_ai.set_defaults(func=cmd_prepare_ai_cache)

    patch = sub.add_parser(
        "patch-xml", help="Patch RadioInfo XML files into a staging output directory"
    )
    add_common_game_arg(patch)
    patch.add_argument("--manifest", required=True, help="manifest.json from prepare-track")
    patch.add_argument(
        "--radio-info", help="Patch only one RadioInfo_*.xml instead of all game languages"
    )
    patch.add_argument("--out-dir", required=True, help="Output directory for patched XML files")
    patch.add_argument(
        "--playlist-mode",
        choices=("add", "only"),
        default="add",
        help="add keeps original playlist entries; only clears FreeRoam/Event first",
    )
    patch.set_defaults(func=cmd_patch_xml)

    package = sub.add_parser(
        "build-package", help="Build a staged FH radio package with rebuilt .assets.bank"
    )
    add_common_game_arg(package)
    package.add_argument(
        "music", nargs="*", help="Music files or directories to pack into the target bank"
    )
    package.add_argument("--out-dir", required=True, help="Output package directory")
    package.add_argument("--radio", type=int, required=True, help="Target FH6 radio number")
    package.add_argument(
        "--source-audio-dir",
        help="Read RadioInfo XML and source banks from this media/audio directory instead of the live game directory",
    )
    package.add_argument(
        "--source-string-tables-dir",
        help="Read StringTables from this directory instead of the live game directory",
    )
    package.add_argument(
        "--baseline-manifest",
        help="Baseline manifest used to complete the package with unchanged protected files",
    )
    package.add_argument(
        "--source", help="Display language to package into the target voice slot, e.g. CHS"
    )
    package.add_argument(
        "--target", help="Voice language slot to package and activate, e.g. EN or JP"
    )
    package.add_argument(
        "--bank",
        help="Target bank name/path under FMODBanks; defaults to the station's first track bank",
    )
    package.add_argument("--playlist-mode", choices=("add", "only"), default="only")
    package.add_argument("--gain-db", type=float, default=-15.0, help=argparse.SUPPRESS)
    package.add_argument("--quality", type=int, default=50, help="fsbankcl vorbis quality")
    package.add_argument("--bpm", default="0")
    package.add_argument(
        "--timing-manifest", help="JSON file with saved per-track marker seconds from the editor"
    )
    package.add_argument(
        "--metadata-cache", help="track_metadata.json with cached per-track loudness analysis"
    )
    package.add_argument(
        "--loudness-jobs",
        type=int,
        default=0,
        help="Parallel song-level workers for cache-miss loudness analysis; default auto",
    )
    package.add_argument(
        "--loudness-offset-lu",
        type=float,
        default=DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU,
        help=(
            "LU offset added to the baseline median loudness target; "
            f"valid range +{MIN_CUSTOM_LOUDNESS_OFFSET_LU:g}..+{MAX_CUSTOM_LOUDNESS_OFFSET_LU:g}, "
            f"default +{DEFAULT_CUSTOM_LOUDNESS_OFFSET_LU:g}"
        ),
    )
    package.add_argument(
        "--playlist-plan",
        help="FH Radio Studio playlist_plan.json (or '-' to read from stdin); when present, build all assigned radios in one package",
    )
    package.add_argument(
        "--playlist-from-package",
        help="Read playlist assignments from an existing FH Radio Studio package manifest or package directory",
    )
    package.add_argument("--ffmpeg", help="Optional ffmpeg executable for mp3/m4a/etc")
    package.add_argument("--fsbankcl", help="Path to fsbankcl.exe. If omitted, PATH is searched.")
    package.add_argument(
        "--allow-truncate", action="store_true", help="Allow more input songs than bank slots"
    )
    package.add_argument(
        "--skip-bank",
        action="store_true",
        help="Generate prepared WAVs and patched XML without running fsbankcl",
    )
    package.add_argument(
        "--progress-jsonl",
        action="store_true",
        help="Emit structured package build progress events to stderr",
    )
    package.set_defaults(func=cmd_build_package)

    baseline = sub.add_parser(
        "baseline", help="Manage pristine game baselines for the files FH Radio Studio will modify"
    )
    baseline_sub = baseline.add_subparsers(dest="baseline_action", required=True)
    baseline_plan_parser = baseline_sub.add_parser(
        "plan", help="List the exact files FH Radio Studio would include in a baseline"
    )
    add_common_game_arg(baseline_plan_parser)
    baseline_plan_parser.add_argument(
        "--package-dir",
        help="Optional package directory to narrow the plan to one package's deployable files",
    )
    baseline_plan_parser.add_argument(
        "--baseline-manifest", help="Existing baseline manifest used to show per-file backup status"
    )
    baseline_plan_parser.add_argument(
        "--preferred-path", help="Override the UserPreferredLang file path"
    )
    baseline_plan_parser.add_argument(
        "--jobs",
        type=int,
        default=0,
        help="Parallel MD5 worker count; default auto uses half of logical CPU cores for large plans",
    )
    baseline_plan_parser.add_argument(
        "--progress-jsonl",
        action="store_true",
        help="Emit structured MD5 progress events to stderr",
    )
    baseline_plan_parser.add_argument("--json", action="store_true", help="Print the plan as JSON")
    baseline_plan_parser.set_defaults(func=cmd_baseline)
    baseline_create = baseline_sub.add_parser(
        "create", help="Create a pristine or pending-verify baseline from current game files"
    )
    add_common_game_arg(baseline_create)
    baseline_create.add_argument(
        "--package-dir",
        help="Optional package directory whose file list narrows what to baseline. When omitted, FH Radio Studio backs up all RadioInfo XML, R*_Tracks*.assets.bank files, and StringTables zips.",
    )
    baseline_create.add_argument(
        "--preferred-path", help="Override the UserPreferredLang file path"
    )
    baseline_create.add_argument("--out-dir", required=True, help="Baseline output directory")
    baseline_create.add_argument(
        "--state", choices=("current", "pending-verify"), default="current"
    )
    baseline_create.add_argument(
        "--jobs",
        type=int,
        default=0,
        help="Parallel MD5 worker count; default auto uses half of logical CPU cores for large plans",
    )
    baseline_create.add_argument(
        "--progress-jsonl",
        action="store_true",
        help="Emit structured MD5 progress events to stderr",
    )
    baseline_create.add_argument("--overwrite", action="store_true")
    baseline_create.add_argument("--yes", action="store_true")
    baseline_create.set_defaults(func=cmd_baseline)
    baseline_promote = baseline_sub.add_parser(
        "promote", help="Promote pending-verify baseline to current"
    )
    baseline_promote.add_argument("--current-dir", required=True)
    baseline_promote.add_argument("--pending-dir", required=True)
    baseline_promote.add_argument(
        "--target-current-dir", help="Destination directory for the promoted current baseline"
    )
    baseline_promote.add_argument("--old-root", required=True)
    baseline_promote.add_argument("--yes", action="store_true")
    baseline_promote.set_defaults(func=cmd_baseline)
    baseline_discard = baseline_sub.add_parser(
        "discard-pending", help="Delete pending-verify baseline"
    )
    baseline_discard.add_argument("--pending-dir", required=True)
    baseline_discard.add_argument("--yes", action="store_true")
    baseline_discard.set_defaults(func=cmd_baseline)
    baseline_apply = baseline_sub.add_parser(
        "apply", help="Copy a saved baseline back into the game directory"
    )
    add_common_game_arg(baseline_apply)
    baseline_apply.add_argument("--baseline-dir", required=True)
    baseline_apply.add_argument("--yes", action="store_true")
    baseline_apply.set_defaults(func=cmd_baseline)
    baseline_bump = baseline_sub.add_parser(
        "bump-build", help="Mark a baseline manifest as compatible with the current Steam build"
    )
    add_common_game_arg(baseline_bump)
    baseline_bump.add_argument("--manifest", required=True, help="Baseline manifest to update")
    baseline_bump.add_argument("--yes", action="store_true")
    baseline_bump.set_defaults(func=cmd_baseline)

    deploy = sub.add_parser(
        "deploy-package",
        help="Copy a built package into FH6 after validating against the pristine baseline",
    )
    add_common_game_arg(deploy)
    deploy.add_argument(
        "package_dir", help="Package directory from build-package, or its package subfolder"
    )
    deploy.add_argument("--baseline-manifest", help="Current pristine baseline manifest")
    deploy.add_argument(
        "--last-applied-manifest",
        help="Read and then update the independent last-applied package fingerprint manifest",
    )
    deploy.add_argument("--preferred-path", help="Override the UserPreferredLang file path")
    deploy.add_argument(
        "--force",
        action="store_true",
        help="Allow deploy when current game files differ from baseline and package",
    )
    deploy.add_argument(
        "--yes",
        action="store_true",
        help="Actually copy files. Without this, only prints a dry run.",
    )
    deploy.set_defaults(func=cmd_deploy_package)

    lang = sub.add_parser("language-swap", help="Inspect FH6 language files and preferred language")
    add_common_game_arg(lang)
    lang_sub = lang.add_subparsers(dest="lang_action", required=True)
    lang_list = lang_sub.add_parser("list", help="List available StringTables zip files")
    add_common_game_arg(lang_list)
    lang_list.set_defaults(func=cmd_language_swap)
    lang_pref = lang_sub.add_parser("preferred", help="Show FH6 UserPreferredLang")
    lang_pref.add_argument("--path", help="Override the UserPreferredLang file path")
    lang_pref.set_defaults(func=cmd_language_swap)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("cancelled", file=sys.stderr)
        return 130
    except CliError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
