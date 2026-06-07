# Design Decisions

This file records notable architectural decisions and the reasoning behind them.
Newest entries go on top. Keep each entry short: what was decided, why, and what
it implies for future work.

## 2026-06-07 — 电台标识统一为 `R{number}`，过滤只按电台名

**决策。** 电台规范标识是 `R{Number}`（直接由 RadioInfo 的 `Number` 派生），不再使用 legacy 名称缩写（`HOR`/`BAS`/`XS`/…）。legacy 缩写只在一次性 migration 中映射回 `R{n}`。电台可见性（隐藏 “Streamer Mode”）只按电台名精确匹配 `streamer mode` 判断，绝不按电台号 / `R10`。

**原因。** 缩写码无法从游戏数据稳定派生，曾导致 App 与 CLI 两套命名漂移；Streamer Mode 的 `Number` 也不可靠。把标识收敛到 `R{Number}`、把过滤收敛到名字，可以删掉所有基于 code/number 的特判。

**影响。**
- `is_ui_supported_radio(name)` / `isUiSupportedRadio(name:)` 是唯一过滤入口，参数只剩 `name`；`R10` / `number == 10` 特判已删除。精确匹配，`"Streamer Mode Remix"` 不会被隐藏。
- package 构建 manifest 用整数 `radio`（+ `station`）表示电台身份，不再冗余输出派生的 `radio_code`。`radio_code`（`R{n}`）仍是 App playlist plan（`reconstruct-plan` 输出 / `build-package` 输入）的标识，CLI 在该边界用 `station_number_by_code` 做 `radio_code ↔ Number` 翻译。
- App 读 package unit 时若缺 `radio_code`，`readPackageUnit` 从整数 `radio` 派生 `R{n}` 兜底。
- legacy 缩写码的唯一归宿是 migration（`migration.py` 的 `_LEGACY_RADIO_CODES`）和迁移检测（`project_workspace.dart` 的 `_legacyRadioCodes`）。

## 2026-06-01 — 项目内路径使用 `fh-project:/` 引用

**决策。** 项目拥有的文件应持久化为 `fh-project:/...` 引用，而不是操作系统绝对路径。规范格式是 `fh-project:/sources/foo.flac`，运行时基于当前打开的项目目录解析。曲目 key 应从规范 `source_ref` 确定性派生，避免依赖项目根目录绝对路径。详见 [项目路径引用设计]。

**原因。** 项目目录应当可以被移动。元数据缓存、时间点配置、塞壬导入记录、baseline manifest 和 package manifest 中的绝对路径会在目录移动后失效。项目本地 URI scheme 可以让项目内存储具备可移植性，同时保留外部游戏、Steam、工具链路径的显式绝对路径语义。

**影响。**
- 新的 durable project JSON 应通过共享路径引用 codec 写入项目内文件路径，避免直接持久化 `File(...).absolute.path` / `Path.resolve()`。
- `fh-project:/...` 只存在于持久化读写边界；读入后立即解析成运行时绝对路径，业务处理、音频分析、package 构建等流程继续使用本机绝对路径和 `track_key`。
- JSON writer / repository 层不能原样落盘上层传入的 entry map；只要字段表示项目相关资源，写入前必须统一编码成 `fh-project:/...` 或 `track_key -> source_ref`。
- legacy 绝对路径迁移只作为 0.1.0 -> 0.2.0+ 的一次性兼容桥；项目缺少 `path_schema` / `current_project_dir` 时才运行，不做每次打开的通用刷新，也不推断未知旧根目录。
- 迁移完成后的正常 reader 不允许用项目内 legacy 绝对 `source` / `path` fallback；遇到这种记录应视为 migration/schema 错误。
- 过渡期 schema 如果输出兼容的绝对 `source` 字段，它只能服务旧消费者或人工诊断；长期权威字段是 `source_ref` 和由它派生的 `track_key`。

## 2026-05-30 — Playlist plans flow over stdin/stdout, not a shared file

**Decision.** The playlist draft is authoritative in memory (Dart
`playlistPlanProvider`) and is no longer persisted to
`.fh-radio-studio/playlist_plan.json` on every edit. The UI ↔ CLI handoff uses
process pipes: `reconstruct-plan --out -` emits the schema_version 2 plan as a
marker-prefixed (`FH_RADIO_STUDIO_PLAN`) compact JSON line on stdout (human
summary on stderr), and `build-package --playlist-plan -` reads the plan from
stdin. The CLI's file-path modes (`--out <path>` / `--playlist-plan <path>`) and
`PlaylistPlanStore.read` / `delete` are retained for legacy file compatibility.

**Why.** Both the UI (per edit, outside the busy lock) and the CLI
(`reconstruct-plan`) wrote the same file, with a real race window during build
that could silently clobber an in-flight edit. A single in-memory authority plus
pipe transport removes the dual-writer surface entirely; for the game-diff seed
the plan never touches disk (reconstruct stdout → memory → build stdin).

**Implications.**
- This refines the 2026-05-29 entry below: ownership is unchanged (the CLI is
  still the source of truth); only the transport moved from a shared file to
  stdout/stdin, and the plan stays an editable in-memory draft.
- `build-package --playlist-plan -` reads stdin once into a buffer because it
  parses the plan twice (builtin targets + groups); stdin is consumed a single
  time.
- The "structured command output" in Frontend/Backend Separation now defaults to
  JSON on stdout for plans; a written file is the compatibility path.

## 2026-05-29 — Playlist reconstruction belongs in the CLI, not the UI

**Decision.** The "rebuild a playlist plan from the live game" workflow — diff the
current game `RadioInfo_*.xml` against the trusted baseline, identify the custom
(self-added) tracks, and resolve them back to project source files — is owned by
the Python CLI, exposed as the `reconstruct-plan` subcommand. The Flutter app
calls it and reads the result back (see the 2026-05-30 entry above for the
stdin/stdout transport that superseded the shared `playlist_plan.json` file). The
UI does not parse RadioInfo XML or match tracks by title/artist on its own.

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
- `reconstruct-plan` emits the same schema_version 2 document (`assignments` +
  `builtin_targets`) the build consumes, so the reconstructed plan stays an
  editable draft in the playlist screen.
- Radio scoping (`is_ui_supported_radio`) lives canonically in the CLI; the Dart
  `isUiSupportedRadio` mirror is applied only when consuming CLI output to hide a
  station in the UI, not for reconstruction. Station visibility is gated by name
  only (exact `streamer mode`), never by radio number / `R10`. Radio codes are
  canonical `R{Number}` — see the 2026-06-07 entry.
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
[项目路径引用设计]: project-path-references.md
