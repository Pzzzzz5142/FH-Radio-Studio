# Design Decisions

This file records notable architectural decisions and the reasoning behind them.
Newest entries go on top. Keep each entry short: what was decided, why, and what
it implies for future work.

## 2026-05-29 — Playlist reconstruction belongs in the CLI, not the UI

**Decision.** The "rebuild a playlist plan from the live game" workflow — diff the
current game `RadioInfo_*.xml` against the trusted baseline, identify the custom
(self-added) tracks, and resolve them back to project source files — is owned by
the Python CLI, exposed as the `reconstruct-plan` subcommand. The Flutter app
calls it, points `--out` at `.fh-radio-studio/playlist_plan.json`, and then reads
the result back through `PlaylistPlanStore`. The UI does not parse RadioInfo XML
or match tracks by title/artist on its own.

**Why.** The CLI is the single source of truth for track metadata: `scan-metadata`
writes the metadata cache, `build-package` consumes the playlist plan, and
`game.py` already parses RadioInfo. An earlier implementation reconstructed the
plan inside `app/lib/state/studio_state.dart` with its own XML parser, filename
guessing, and `title|artist` matching. That created a second, parallel metadata
mechanism in Dart that could drift out of sync with the CLI's resolution rules.

**Implications.**
- New logic that reads FH6 files, resolves track metadata, or maps tracks to
  sources goes in the CLI and is surfaced through a structured command output,
  not reimplemented in the UI. See [Frontend/Backend Separation in `AGENTS.md`].
- `reconstruct-plan` emits the same `playlist_plan.json` schema that
  `PlaylistPlanStore` reads (`assignments` + `builtin_targets`), so the
  reconstructed plan stays an editable draft in the playlist screen.
- Radio scoping (`is_ui_supported_radio`) and radio-code labeling
  (`radio_code_for_station`) now have one canonical home in the CLI; the Dart
  `isUiSupportedRadio` / `_radioAssignmentLabel` helpers remain only for purely
  presentational use, not for reconstruction. Station visibility is gated by
  name only (the "Streamer Mode" station), never by radio number / `R10`.
- Package build inputs always come from the project (`sources` / `siren`) plus a
  playlist plan, never from a prepared package directory — the prepared package
  is the build output dir and is cleared before each build. When a rebuild needs
  the current package's track set (e.g. a loudness-only change with no draft),
  seed a plan from the package manifest's `assignments` (whose `source` fields
  point at the project files) and build with `--playlist-plan`, rather than
  pointing `--playlist-from-package` at the dir being overwritten.
- When the playlist screen derives a plan from a prepared package
  (`playlistPlanFromCatalog`), the package manifest's `sound_name → source` map
  is authoritative; `title|artist` pool matching is only a fallback.

[Frontend/Backend Separation in `AGENTS.md`]: ../AGENTS.md
