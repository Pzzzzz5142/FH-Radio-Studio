# 项目路径引用设计

状态：已实现

本文定义 FH Radio Studio 如何在持久化数据里引用项目拥有的文件。目标是让项目目录可以自由移动，不需要重写每一个 JSON 缓存或 manifest，同时让真正的外部路径继续保持明确、可审计、跨平台可用。

## 问题

当前项目 JSON 中持久化了大量指向项目根目录内部的绝对路径，例如：

- `.fh-radio-studio/track_metadata.json`
- `analysis/track_timing.json`
- `analysis/build_timing_manifest.json`
- `siren/siren_imports.json`
- `backups/*/baseline_manifest.json`
- `packages/*/package/fh_radio_studio_package_manifest.json`
- `.fh-radio-studio/last_applied_package_manifest.json`

用户移动项目目录后，这些路径仍然指向旧位置，导致元数据、时间点、播放列表、准备包记录等信息失效。但同一批 JSON 中也存在合法的外部绝对路径，例如 FH6 游戏目录、Steam manifest 路径、工具链路径。因此长期方案不能只是对所有字符串做全局替换。

## 决策

项目拥有的文件必须持久化为项目引用，而不是操作系统绝对路径。规范字符串格式为：

```text
fh-project:/sources/foo.flac
fh-project:/siren/MSR-232264.wav
fh-project:/analysis/track_timing.json
fh-project:/backups/baseline-current/baseline_manifest.json
fh-project:/packages/current/package/fh_radio_studio_package_manifest.json
```

`fh-project` URI scheme 只在 FH Radio Studio 内部使用。它不是系统级协议处理器，也不能直接交给文件系统 API 打开。Flutter App 和 Python CLI 必须先把它解析到当前打开的项目目录下，再进行实际文件操作。

持久化时所有项目引用都使用 `/` 作为分隔符。只有运行时解析到本机文件路径时，才转换成宿主平台路径。

## URI 形态

规范格式：

```text
fh-project:/<project-relative-path>
```

规则：

- scheme 必须严格等于 `fh-project`。
- URI 不带 authority，也不带 host。
- URI path 在 URI 语义上是绝对路径，但在产品语义上表示“相对当前项目根目录”。
- 第一个路径段必须是项目拥有的固定根之一：`.fh-radio-studio`、`analysis`、`backups`、`packages`、`siren`、`sources`。
- `.` 和空路径段会被规范化移除。
- `..` 非法。
- URI path 内禁止 Windows 盘符、UNC 路径、以及以双斜杠开头的路径。
- URI 特殊字符，例如 `%`、`?`、`#` 等，写入时必须由 codec percent-encode；读取时必须逐段 decode，再校验 decode 后的路径段。

读取端只需要支持规范格式 `fh-project:/...`。迁移期的兼容对象是旧 schema 中已经存在的操作系统绝对路径，而不是其他 `fh-project` URI 变体。所有新写入都必须输出 `fh-project:/sources/foo.flac` 这种规范格式。

## 外部路径

外部资源继续使用普通绝对路径。例子：

- FH6 游戏目录。
- Steam app manifest 路径。
- 位于项目外部的用户首选语言文件。
- 工具链、模型缓存、音频工具路径。
- 导入前的用户源文件。

外部路径不使用 `fh-project:/`。

## 曲目身份

项目曲目的可恢复身份必须从规范项目引用派生。`fh-project:/...` 已经消除了项目根目录移动带来的绝对路径不稳定性，因此同一个项目内文件可以通过它的规范 `source_ref` 稳定地产生 key：

```json
{
  "source_ref": "fh-project:/sources/foo.flac",
  "track_key": "trkref_..."
}
```

`track_key` 的输入必须是经过 codec 规范化后的 `source_ref`，而不是本机绝对路径。算法：

```text
track_key = "trkref_" + first_128_bits_as_lowercase_hex(sha256(canonical_source_ref))
```

也就是取 SHA-256 digest 的前 128 bit，编码成 32 个 lowercase hex 字符。128 bit 对单个本地项目的曲目规模已经足够宽裕，同时比完整 SHA-256 更短、更适合在 UI 和日志中展示。

这样在 `track_key` 字段缺失时，只要能得到规范 `source_ref`，就能重新计算出同一个 key。项目目录从 `C:\A` 移到 `D:\B` 不影响 key，因为 `source_ref` 仍然是 `fh-project:/sources/foo.flac`。

0.2.0+ 正常业务代码读取项目曲目时必须是 strict mode：

1. 如果业务记录有 `track_key`，使用它并通过资产索引解析到 `source_ref`。
2. 如果资产索引项缺少 `track_key` 但有 `source_ref`，规范化后派生 `track_key`。
3. 如果是扫描项目内文件得到的路径，先转换成 `source_ref`，再派生 `track_key` 并写入资产索引。
4. 如果 0.2.0+ durable project JSON 里只剩 legacy `source` / `path` 项目内绝对路径，视为 schema 错误或 migration 未完成，必须报错，不允许作为 fallback 读取。
5. 外部路径不能生成项目 `track_key`，除非先被导入项目。

只有专属 migration tool 可以读取 legacy 项目内绝对路径，并把它一次性转换为资产索引 `source_ref` + `track_key`。迁移完成后的正常代码路径不能再保留“如果没有 `track_key` 就尝试读绝对路径”的兜底逻辑。

不要用操作系统绝对路径、未规范化相对路径、标题/艺术家元数据、或内容 hash 作为主 key。这些值可能随项目移动、标签编辑、封面变化、转码或读取策略变化而改变。文件名和项目相对路径可以通过 `source_ref` 参与身份，但必须先进入规范 URI 形态。

随机 UUID/ULID 可以作为项目资产索引里的可选记录 id，用于审计或 UI 内部引用，但不能作为唯一身份来源。因为它是在初始化时决定的，字段缺失时无法从文件本身恢复。长期目标是：播放列表、时间点、元数据、塞壬导入记录优先引用可重建的 `track_key`；资产索引可额外保存 `asset_id`、`source_ref` 和修复提示。

## JSON 存储方向

0.2.0 schema 使用以下形态：

```json
{
  "schema_version": 2,
  "tracks": [
    {
      "track_key": "trkref_...",
      "source_ref": "fh-project:/sources/foo.flac"
    }
  ]
}
```

上面的结构表示项目曲目资产索引。业务记录不再把本机路径当成身份，也不需要重复保存 `source_ref`；它们只引用 `track_key`：

```json
{
  "schema_version": 2,
  "assignments": [
    {
      "track_key": "trkref_...",
      "radio_code": "R4",
      "playlist_type": "FreeRoam",
      "slot": 1
    }
  ]
}
```

如果为了旧消费者保留一个发布周期的兼容字段，schema 最多只能把 legacy 字段当成非权威输出：

```json
{
  "track_key": "trkref_...",
  "source": "C:\\Users\\Alice\\FH Radio Studio\\sources\\foo.flac"
}
```

兼容字段 `source` 只用于旧消费者或人工诊断。0.2.0+ 新读取代码不得使用项目内绝对 `source` / `path` 作为 fallback；发现它是唯一可用项目内引用时应报告 migration/schema 错误。权威映射是资产索引里的 `track_key -> source_ref`，业务 JSON 的权威引用是 `track_key`。

## 运行时边界

`fh-project:/...` 是持久化格式，不是业务层的运行时数据模型。URI 只应该出现在 JSON 读写边界：

- 读取 durable project JSON 时：严格校验 `fh-project:/...`，然后立即加当前项目目录，解析为用于文件操作的本机绝对路径。
- 写入 durable project JSON 时：位于项目根目录内的运行时绝对路径统一转换为 `fh-project:/...`。
- 位于项目根目录外的路径保留为外部绝对路径。
- codec 必须校验解析后的项目引用仍然位于项目根目录内。

读写之外，Flutter 和 CLI 的业务逻辑、音频处理、metadata 解析、package 构建、文件复制等流程都应该只接触本机绝对路径和 `track_key`，不直接考虑 URI。这样可以保持现有处理代码简单，也能把跨平台路径规则集中在少量 persistence codec / repository 层。

Dart App 和 Python CLI 需要等价的读写边界行为。写入持久项目 JSON 字段时，不要在各处手写 `File(path).absolute.path`、`p.canonicalize(...)` 或 `Path.resolve()`；读取持久项目 JSON 字段时，也不要在业务代码里零散解析 URI。

writer / repository 层不能只是把上层传下来的 entry map 原样写进 JSON。凡是 durable project JSON，writer 必须根据当前 schema 明确识别项目资源字段，并在最终 `JsonEncoder` / `write_json()` 前统一做持久化编码：

- 项目内资源路径必须写成 `fh-project:/...`，或通过资产索引写成 `track_key -> source_ref`。
- 业务层传入的本机绝对路径只能视为运行时值；writer 负责把它转换成持久化 URI。
- 如果上层已经传入 `fh-project:/...`，writer 仍要规范化和校验，不能盲信字符串。
- 如果项目相关资源字段无法编码成 URI / `track_key`，应 fail fast，而不是把绝对路径落盘。

换句话说，JSON writer 是最后一道持久化边界。上层可以为了处理方便传递绝对路径，但项目相关资源不能因为“entry 已经组好了”就绕过 URI/资产索引规则。

### 写入门禁

0.2.0+ 的 durable project JSON 不应该直接调用底层 JSON sink 写入。Dart 和 Python 都有项目专属 writer，它们会在落盘前扫描 path-like 字段：

- 项目内绝对路径：拒绝写入，要求先编码为 `fh-project:/...` 或 `track_key`。
- `fh-project:/...`：规范化并校验；非法 URI 直接失败。
- 项目外绝对路径：保留为外部路径，例如 `game_dir`、`audio_dir`、`source_game_path`。

Dart 写入项目 JSON 时使用：

```dart
writeProjectJsonSync(
  projectDir: projectDir,
  file: file,
  payload: payload,
);
```

对应实现位于 `app/lib/core/project_json_guard.dart`。不要在 durable project JSON writer 中直接写：

```dart
file.writeAsStringSync(
  const JsonEncoder.withIndent('  ').convert(payload),
  encoding: utf8,
);
```

Python CLI 写入项目 JSON 时使用：

```python
write_project_json(path, payload, project_dir=project_dir)
```

对应实现位于 `backend/fh_radio_studio_cli/project_json_guard.py`。不要在 durable project JSON writer 中直接写：

```python
write_json(path, payload)
```

`write_json()` 仍可用于非项目 schema JSON，例如工具链 manifest、外部工具状态、AI cache，或 CLI stdout 之外的普通 JSON 工具文件。`print(json.dumps(...))` / marker-prefixed stdout 也不属于 durable project JSON，不需要走 project guard。

新增或修改 writer 时的判断标准：如果文件位于 `.fh-radio-studio/`、`analysis/`、`siren/`、`backups/`、`packages/` 且会被项目重新打开后读取，就应走项目专属 writer。测试中如需构造坏旧数据，可以手写 JSON；产品代码写回时必须经过 guard。

## 迁移

从现有绝对路径 schema 迁移由一次性的专属 `0.1.0 -> 0.2.0+` migration tool 完成。迁移功能从 0.2.0 起生效；不支持根据 JSON 内容推断未知旧项目根目录。打开项目时，当前用户选择的目录就是唯一可信的项目根。

迁移器职责：

- 在 Dart 和 Python 中添加项目引用 codec。
- 在 `.fh-radio-studio/project.json` 中新增项目格式字段，作为 0.2.0+ 项目标记，并记录当前打开的项目目录：

```json
{
  "schema": 2,
  "path_schema": 2,
  "current_project_dir": "C:\\Users\\Alice\\FH Radio Studio"
}
```

- 如果打开项目时缺少 `path_schema` / `current_project_dir`，则认定它是 0.1.0 项目，运行一次专属 `0.1.0 -> 0.2.0+` migration。
- 迁移器由 Flutter 打开项目流程触发，并调用 CLI 中对应的迁移能力；两侧需要共享同一套字段 allowlist 和测试夹具，避免 UI/CLI 行为漂移。
- 这不是每次打开都执行的通用刷新。新项目初始化或迁移成功后才写入 `path_schema`；普通 settings 写入不得用 `path_schema` 证明迁移完成。后续打开只更新 `current_project_dir` 作为诊断/最近打开记录，不再重扫所有 JSON。
- migration 中：
  - 已经是规范 `fh-project:/...` 的字段保持不变。
  - 位于当前项目根目录内的 legacy 绝对路径改写为 `fh-project:/...`。
  - 位于当前项目根目录外的绝对路径保持不变，视为外部路径。
- 项目曲目资产索引并入 `.fh-radio-studio/track_metadata.json`：该缓存的每个条目同时持有规范 `source_ref` 和派生 `track_key`，由 CLI `scan-metadata` 扫描 `sources/` 与 `siren/` 生成，业务记录通过 `track_key` 反查它。不再单独维护 `track_assets.json`。
- 为已有项目音频生成规范 `source_ref` 和派生 `track_key`。
- 把时间点、元数据、塞壬记录、播放列表记录改写为引用 `track_key`。
- `source_ref` 留在资产索引里；业务记录不再把源文件绝对路径当成身份。
- 同步更新或淘汰从绝对路径派生出来的 legacy `path_key`。
- 外部路径保持不变。
- 0.2.0 之前已经被移动过、且 JSON 仍指向未知旧根目录的项目，不自动修复；这种情况需要用户重新导入/重建相关缓存，或手动修复后再打开。

不做旧项目根目录推断。迁移器只根据当前项目根判断一个绝对路径是否属于项目；不属于当前项目根的路径一律不改写。`current_project_dir` 不是迁移来源，也不用于反推出旧路径；它只是 0.2.0+ 项目格式标记、诊断信息，以及后续打开时记录当前目录。

迁移器是 legacy 项目内绝对路径的唯一允许读取者。迁移完成后，Flutter 和 CLI 的正常读写路径都必须拒绝“项目内资源绝对路径 fallback”：缺少 `track_key` / 资产索引 / `source_ref` 的项目内资源记录应 fail fast，并提示项目需要迁移或修复。这样可以防止旧字段继续扩散，也避免后续维护时同时背负两套身份规则。

## 当前绝对路径产生点清单

本节记录 2026-06-01 对当前 Dart/CLI 代码和样本项目 `C:\Users\Pzzzzz\Forza Horizon 6 RadioMod` 的扫描结果，方便后续 agent 实现 migration tool 时直接按字段改写，而不是做全局字符串替换。

样本项目中共扫描到 9 个 JSON 文件，约 858 个绝对路径字符串，其中约 788 个位于样本项目根目录内。项目内路径主要出现在：

- `.fh-radio-studio/track_metadata.json`
- `analysis/track_timing.json`
- `analysis/build_timing_manifest.json`
- `siren/siren_imports.json`
- `backups/baseline-current/baseline_manifest.json`
- `backups/baseline-current/derived/bank_order.json`
- `packages/current/package/fh_radio_studio_package_manifest.json`
- `.fh-radio-studio/last_applied_package_manifest.json`

### Dart 写入/转发点

- `app/lib/core/project_workspace.dart`
  - `ProjectWorkspace.writeSettings` 写 `.fh-radio-studio/project.json` 的 `settings.game_dir`、`settings.preferred_path`。
  - `ensureProject` / `collectAudioFiles` 使用本机绝对路径作为运行时文件路径。`game_dir`、`preferred_path` 是外部路径，不参与 `source_ref` 迁移。
- `app/lib/core/path_keys.dart`
  - `canonicalPathKey(path)` 目前用 `File(path).absolute.path` + canonicalize/lowercase 生成 key。
  - 后续项目曲目身份不能继续调用它生成 durable `track_key`；应改为从 canonical `source_ref` 派生。
- `app/lib/core/playlist_plan.dart`
  - `PlaylistAssignment.toJson()` 写 `assignments[].source`。
  - `encodeForCli()` 把 playlist draft 通过 stdin 传给 CLI，仍携带 `source`。
  - `PlaylistPlanStore` 保留 `.fh-radio-studio/playlist_plan.json` 路径读/删兼容，但只消费已迁移/current schema；旧字段由项目迁移负责归一化。
  - `_normalizeProjectSource` 会把 legacy source 规整成本机绝对路径。
  - migration 后 playlist 记录应引用 `track_key`；CLI build 前再通过资产索引解析到运行时绝对路径。正常读取不得回退到 `assignments[].source` 中的项目内绝对路径。
- `app/lib/core/track_timing_config.dart`
  - `TrackTimingConfig.toJson()` 写 `tracks[].source`、`tracks[].path_key`。
  - `TrackTimingStore.writeAll()` 写 `analysis/track_timing.json`。
  - `TrackTimingStore.writeBuildManifest()` 写 `analysis/build_timing_manifest.json`。
  - migration 后时间点记录应引用 `track_key`。正常读取不得回退到 `tracks[].source` / `tracks[].path_key`。
- `app/lib/core/siren_imports.dart`
  - `SirenImportEntry.fromSiren()` 把导入后的 siren 文件保存为 `File(path).absolute.path`。
  - `toJson()` 写 `tracks[].path`、`tracks[].path_key`。
  - `_write()` 写 `siren/siren_imports.json`。
  - migration 后塞壬记录应引用 `track_key`，其 `source_ref` 进入资产索引，例如 `fh-project:/siren/name.wav`。正常读取不得回退到 `tracks[].path` 项目内绝对路径。
- `app/lib/core/track_metadata_cache.dart`
  - 读取/局部重写 `.fh-radio-studio/track_metadata.json`，当前以 `source`、`path_key` 为索引字段。
  - 主要生产者是 CLI `scan-metadata`，但 Dart 删除/保留缓存项时也会重写 JSON。
  - migration 后元数据项应引用 `track_key`；封面路径若位于项目内，应在资产索引或 metadata schema 中用 `fh-project:/...` 表示。正常读取不得用 `source` / `path_key` 重新拼出项目曲目身份。
- `app/lib/state/studio_state.dart`
  - 打开项目时把保存的 project dir 规整为 `File(...).absolute.path`。
  - `setProjectDir` 读写 `.fh-radio-studio/project.json`。
  - `importMusicPaths` / `importSirenTrack` 调 CLI `import-audio`，接收导入后的绝对路径。
  - `_refreshTrackMetadataCacheWithinBusy` 调 CLI `scan-metadata --project-dir ...`，生成 metadata cache。
  - `buildPackage` 调 `TrackTimingStore.writeBuildManifest()` 和 `build-package --playlist-plan -`，把当前 draft 和 timing manifest 交给 CLI。
  - 这些运行时绝对路径可以继续存在于内存和进程参数中；写 durable project JSON 前必须经过 codec/资产索引。
- `app/lib/state/custom_pool_tracks.dart`
  - `realTrackKeyForPath(path)` 当前返回 `canonicalPathKey(path)`，等价于“绝对路径即身份”。
  - 需要改成从资产索引或 `source_ref` 派生 `track_key`。
- `app/lib/screens/replace_editor/replace_state.dart`
  - 保存时间点时构造 `TrackTimingConfig(source: state.track.source, ...)`。
  - 后续应传递/保存 `track_key`。
- `app/lib/core/siren_audio_cache.dart`
  - 写应用级 siren cache manifest，不是项目迁移核心对象。若该 cache 位于项目外，应继续视为外部/临时缓存路径。

### CLI 写入点

- `backend/fh_radio_studio_cli/common.py`
  - `path_key(path)` 目前用 `Path.resolve().casefold()`，是 legacy 路径 key 的共同来源。
  - `write_json()` 是 CLI 原始 JSON sink，不应该承担 schema 语义。新 durable project JSON 应由项目专属 writer/repository 在调用 `write_json()` 前统一编码项目资源字段；业务调用点不应把未编码的 entry map 直接交给 `write_json()`。
- `backend/fh_radio_studio_cli/import_audio.py`
  - `cmd_import_audio` 返回 `project_dir`、`sources_dir`、`target_dir`、`imported[]`。
  - `_result` 写 `imported[].source` 和 `imported[].path`，都是绝对路径。
  - 这些可作为命令结果给 UI 使用；若写入项目资产索引，导入后的 `path` 应转换为 `source_ref`。
- `backend/fh_radio_studio_cli/metadata.py`
  - `cmd_scan_metadata` 写 `.fh-radio-studio/track_metadata.json`。
  - `build_track_metadata_cache_entry` 写 `tracks[].source`、`tracks[].path_key`、`tracks[].cover_art_path`。
  - `cached_loudness_analysis_for_path` 写 `tracks[].loudness_analysis.source`。
  - migration 后 metadata cache 应以 `track_key` 连接资产索引；项目内 cover art 路径应写 `fh-project:/...` 或改为相对资产引用。
- `backend/fh_radio_studio_cli/reconstruct_plan.py`
  - `_project_sources_by_metadata` 用 metadata cache 和扫描文件解析出本机绝对 source。
  - `reconstruct_playlist_plan` 输出 `assignments[].source`。
  - migration 后 reconstruct 输出应给 `track_key`；build 时再解析成运行时路径。正常读取不得回退到 metadata cache 里的项目内绝对 `source`。
- `backend/fh_radio_studio_cli/baseline.py`
  - `baseline_manifest.json` 写 `game_dir`、`files[].source_game_path`、`files[].backup_path`、`files[].package_path`、`package_audio`、`baseline_manifest` 等。
  - `source_game_path`、`game_dir` 是游戏安装外部路径，不能迁移为 `fh-project:/`。
  - `backup_path` 若位于当前项目根内，可用 `install_relative_path` 推导，或迁移为 `fh-project:/backups/...`；外部 backup 路径保持不变。
  - `package_path` 若指向项目内 `packages/...`，可迁移为 `fh-project:/packages/...`。
- `backend/fh_radio_studio_cli/baseline_order.py`
  - `derived/bank_order.json` 写 `source_baseline_manifest`。
  - 若该 manifest 在项目内，应迁移为 `fh-project:/backups/.../baseline_manifest.json`。
- `backend/fh_radio_studio_cli/package.py`
  - `package_file_fingerprints()` 写 `package_files[].path`。
  - `prepare_music_tracks()` 写 `music[].source`、`music[].prepared_wav`。
  - package manifest 写 `game_dir`、`source_audio_dir`、`source_radio_info`、`source_bank`、`playlist_plan`、`timing_manifest`、`radios[].assignments[].source`、`radios[].assignments[].staged_wav`、language 相关 source/target table 路径。
  - `game_dir`、来自游戏安装或外部语言目录的路径保持外部绝对路径。
  - 位于项目内的 `playlist_plan`、`timing_manifest`、`prepared_wav`、`staged_wav`、`package_files[].path` 可迁移为 `fh-project:/...`；曲目来源应通过 `track_key`/资产索引表达。
  - 当前 `build-package --playlist-plan -` 会把 `-` 解析成运行目录下的路径写入 manifest，这是独立 bug；应存 `null` 或字面量 `-`，不能参与项目路径迁移。
- `backend/fh_radio_studio_cli/deploy.py`
  - `_write_last_applied_manifest` 写 `.fh-radio-studio/last_applied_package_manifest.json` 的 `source_package_manifest`、`package_root`。
  - 这两个字段通常指向项目内 package，应迁移为 `fh-project:/packages/...`；该 manifest 也可能保留 package manifest 的 `radios[].music` / `radios[].assignments` 曲目引用，应按 package manifest 规则迁移为 `track_key`。
  - deploy 临时 manifest 中的 `files[].source`、`files[].destination` 是部署过程诊断；`destination` 是游戏安装路径，应保持外部绝对路径。
- `backend/fh_radio_studio_cli/prepare.py`
  - prepare-track manifest 写 `source`、`wav`，通常是临时/构建产物；只有写进项目 durable JSON 时才纳入迁移。
- `backend/fh_radio_studio_cli/status.py`、`game.py`、`external_tools.py`、`toolchain.py`、`ai_timepoints/*`
  - 这些模块会输出游戏、Steam、工具链、模型、分析 cache 路径。
  - 默认视为外部或临时诊断路径；不要被项目迁移器全局替换。

### Migration allowlist

迁移器应采用文件路径 + JSON 字段 allowlist，而不是扫描所有字符串。建议第一批 allowlist：

- `.fh-radio-studio/track_metadata.json`
  - `tracks[].source`：若在当前项目根内，写入资产索引为 `source_ref`，记录改为 `track_key`。
  - `tracks[].path_key`：由 `track_key` 替代或仅保留 legacy 兼容字段。
  - `tracks[].cover_art_path`：项目内路径改为 `fh-project:/...`；外部路径保持不变。
  - `tracks[].loudness_analysis.source`：改为 `track_key` 或移除重复 source。
- `analysis/track_timing.json`
  - `tracks[].source`、`tracks[].path_key` -> `track_key`。
- `analysis/build_timing_manifest.json`
  - `tracks[].source`、`tracks[].path_key` -> `track_key`。
- `siren/siren_imports.json`
  - `tracks[].path`、`tracks[].path_key` -> `track_key`，`source_ref` 写入资产索引。
- `.fh-radio-studio/playlist_plan.json`，如果 legacy 文件存在
  - `assignments[].source` -> `track_key`。
- `packages/*/package/fh_radio_studio_package_manifest.json`
  - 项目内曲目来源、timing manifest、package files、prepared/staged wav 可迁移；游戏目录、source bank、source audio dir 若来自游戏/baseline 外部目录则保持绝对路径。
- `backups/*/baseline_manifest.json`
  - 项目内 `backup_path` / `package_path` 可迁移；`game_dir`、`source_game_path` 保持外部绝对路径。
- `backups/*/derived/bank_order.json`
  - 项目内 `source_baseline_manifest` 可迁移。
- `.fh-radio-studio/last_applied_package_manifest.json`
  - 项目内 `source_package_manifest`、`package_root` 可迁移；若包含 package manifest 的 `radios[].music` / `radios[].assignments`，曲目来源同样迁移为 `track_key`。

明确不迁移：

- `.fh-radio-studio/project.json` 的 `settings.game_dir`、`settings.preferred_path`。
- Steam manifest、FH6 安装目录、游戏 `media/audio` 路径、用户语言文件路径。
- 工具链、uv、ffmpeg/vgmstream/fsbankcl、AI model/cache 路径。
- 不在当前项目根目录下的任何绝对路径。

除 migration tool 外，正常 0.2.0+ 代码必须把 allowlist 中残留的项目内 legacy 绝对路径视为错误，而不是兼容读取入口。

## Package 和 Baseline Manifest

package / baseline manifest 目前包含许多用于审计和诊断的绝对路径。长期持久化应优先使用：

- 项目内文件用 `source_ref`。
- 游戏安装目标用 `install_relative_path`。
- `game_dir` 和 Steam manifest 路径保留外部绝对路径。
- 可部署包内容优先使用 `package_files[].relative_path` 和 `install_relative_path`。

`prepared_wav`、`staged_wav` 这类准备工作目录路径属于构建产物。若持久化后仍对诊断有价值，可以存成 `fh-project:/packages/...`；否则可以从 durable manifest 中省略。

当 `build-package --playlist-plan -` 从 stdin 读取计划时，持久化 manifest 不应把 `-` 解析成文件路径。应根据 schema 存 `null` 或字面量 `-`。

## 测试计划

需要补充以下测试：

- Dart codec 在 Windows 和 POSIX 风格输入下的 parse、normalize、resolve、serialize 行为。
- Python codec 与 Dart 规则保持一致。
- 拒绝 `..`、盘符、UNC 路径、空路径、以及逃逸项目根目录的路径。
- 代表性 JSON 文件中的 legacy 绝对路径迁移。
- 迁移时保留外部游戏路径和 Steam 路径。
- 项目移动后，由同一 `source_ref` 派生的 `track_key` 仍然稳定。
- `track_key` 字段缺失时，可以从规范 `source_ref` 重新计算。
- 迁移完成后的正常 reader 遇到项目内 legacy 绝对 `source` / `path` 且缺少 `track_key` 时必须失败，不能 fallback。
- writer/repository 测试：即使上层传入的 entry 含项目内绝对路径，最终落盘 JSON 也必须是 `fh-project:/...` 或 `track_key`；如果不能编码则失败。
- CLI/UI handoff 在解析 refs 后仍然收到可用于文件操作的绝对运行时路径。

## 未决问题

- 项目资产索引应该放在哪里：`.fh-radio-studio/tracks.json`，还是并入 `track_metadata.json`？并入。`track_metadata.json` 即权威 `track_key -> source_ref` 索引，不另建独立文件。
- 如果用户在应用外重命名或移动项目内音频，是否需要基于内容指纹做辅助修复，还是把它视为新 `source_ref` / 新 `track_key`？我们不允许这样，我们都是import到source或者msr里面。不存在这种情况
- 生成的 package manifest 是否需要保留一个发布周期的兼容 `source` 字段，还是直接切换到 `source_ref`？切换
- CLI `migrate-project` 是否需要提供 dry-run / report 模式，方便用户和测试查看会改写哪些 JSON 字段？不用
