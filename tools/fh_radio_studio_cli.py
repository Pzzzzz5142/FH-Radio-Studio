#!/usr/bin/env python3
"""Compatibility entrypoint for the FH Radio Studio CLI.

The implementation lives in backend/fh_radio_studio_cli. Keep this shim so older
scripts that call tools/fh_radio_studio_cli.py continue to work.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from backend.fh_radio_studio_cli.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
