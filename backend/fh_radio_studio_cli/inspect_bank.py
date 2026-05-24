from __future__ import annotations

from .common import *
from .fsb5 import bank_name_from_path, parse_fsb5
from .game import audio_dir_for, resolve_game_dir
from .package import resolve_target_bank


def cmd_inspect_bank(args: argparse.Namespace) -> int:
    bank = Path(args.bank).expanduser()
    if not bank.exists():
        game_dir = resolve_game_dir(args.game_dir)
        audio_dir = audio_dir_for(game_dir)
        bank = resolve_target_bank(audio_dir, args.radio, args.bank)
    info = parse_fsb5(bank)
    print(f"Bank        : {bank}")
    print(f"FSB5 offset : {info.bank_offset}")
    print(f"FSB5 size   : {info.total_size}")
    print(f"Samples     : {info.num_samples}")
    width = max(2, len(str(info.num_samples)))
    for sample in info.samples[: args.limit]:
        print(
            f"  {sample.index + 1:0{width}d}. "
            f"{sample.name or '<unnamed>'} | {sample.frequency} Hz | "
            f"{sample.channels} ch | {sample.sample_count} samples"
        )
    if info.num_samples > args.limit:
        print(f"  ... {info.num_samples - args.limit} more")
    return 0
