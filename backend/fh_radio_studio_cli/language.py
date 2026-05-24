from __future__ import annotations

from .common import *
from .game import resolve_game_dir


def string_tables_dir_for(game_dir: Path) -> Path:
    path = game_dir / "media" / "Stripped" / "StringTables"
    if not path.is_dir():
        die(f"StringTables directory not found: {path}")
    return path


def default_user_preferred_lang_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        base = Path(local_app_data)
    else:
        base = Path.home() / "AppData" / "Local"
    return base / "ForzaHorizon6" / "UserPreferredLang"


def resolve_user_preferred_lang_path(path: Optional[str] = None) -> Path:
    if path:
        return Path(path).expanduser()
    return default_user_preferred_lang_path()


def normalize_text_language(lang: str) -> str:
    value = lang.strip().upper()
    aliases = {
        "CN": "CHS",
        "ZH": "CHS",
        "ZH-CN": "CHS",
        "CHINESE": "CHS",
        "SIMPLIFIED": "CHS",
        "TW": "CHT",
        "ZH-TW": "CHT",
        "TRADITIONAL": "CHT",
        "JA": "JP",
        "JAPANESE": "JP",
        "ENG": "EN",
        "ENGLISH": "EN",
    }
    return aliases.get(value, value)


def normalize_preferred_language(lang: str) -> str:
    value = lang.strip().upper()
    if value == "AUTO":
        return "auto"
    return normalize_text_language(value)


def read_user_preferred_lang(path: Path) -> Optional[str]:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8", errors="replace").strip()


def write_user_preferred_lang(path: Path, lang: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(lang, encoding="utf-8")


def cmd_language_swap(args: argparse.Namespace) -> int:
    if args.lang_action == "preferred":
        pref_path = resolve_user_preferred_lang_path(args.path)
        current = read_user_preferred_lang(pref_path)
        print(f"UserPreferredLang: {pref_path}")
        print(f"Current          : {current if current is not None else '<missing>'}")
        return 0

    game_dir = resolve_game_dir(args.game_dir)
    string_dir = string_tables_dir_for(game_dir)

    if args.lang_action == "list":
        print(f"StringTables: {string_dir}")
        for path in sorted(string_dir.glob("*.zip")):
            print(f"  {path.stem:<4} {path.name:<8} {path.stat().st_size}")
        return 0

    die(f"Unknown language action: {args.lang_action}")
