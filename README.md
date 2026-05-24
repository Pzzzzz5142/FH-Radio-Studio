# FH Radio Studio

FH Radio Studio 是一个面向 **Forza Horizon 6 PC 版自定义电台** 的桌面工具和 Python CLI。它的目标不是做一个黑箱“一键改游戏”的脚本，而是把音频导入、时间点确认、准备包生成、文件校验和写入游戏这条链路做成可审计、可重复、可验证的工作流。

项目当前由两部分组成：

- `app/`：Flutter 桌面 App，提供项目管理、播放列表编辑、AI 时间点确认、工具链状态、文件校验和写入游戏 UI。
- `backend/fh_radio_studio_cli/`：Python CLI，负责读取 FH6 文件、分析音频、生成准备包、记录原始备份和写入游戏文件。

## 适合谁

- 想把 FH6 原电台里的歌曲替换成自选音乐的玩家。
- 想保留比赛开始、冲线、漫游、循环段体验，而不是简单粗暴地把一首歌塞进 bank。
- 想用项目目录管理音源、准备包、原始备份和分析缓存的人。
- 想直接从 **MONSTER SIREN 塞壬唱片**挑歌、试听并导入到电台池的人。
- 想通过 CLI 自动化或调试 FH6 RadioInfo / bank 处理流程的开发者。

## 塞壬唱片支持

FH Radio Studio 内置 **MONSTER SIREN 塞壬唱片**入口。你可以在 App 里浏览塞壬唱片专辑和歌曲，试听音频，把喜欢的曲目加入导入队列，然后一键导入到当前项目。

导入后的塞壬歌曲会进入项目的 `siren/` 音源区，并保留歌曲名、艺术家、专辑、封面和 MSR 来源标识。它们会和本地导入的 `.mp3` / `.flac` / `.wav` 一样出现在歌曲池里，可以直接分配到 FH6 电台、运行 AI 时间点分析、生成准备包并写入游戏。

## 核心概念

FH Radio Studio 使用一个自包含项目目录，默认是：

```text
<home>/FH Radio Studio/
```

目录结构：

```text
sources/          用户导入的本地音频
siren/            塞壬唱片导入记录和音频
packages/         准备包和测试准备包
backups/          原始备份和新游戏文件记录
analysis/         波形、AI、响度、timing 等分析缓存
.fh-radio-studio/ 项目设置、播放列表草稿、歌曲 metadata 和写入记录
```

安全模型很简单：

- 先在文件校验里创建原始备份，记录 FH Radio Studio 会保护的 FH6 文件。
- 生成准备包时只写入项目目录，不直接改游戏。
- 写入游戏前会重新扫描受保护文件，确认当前状态可以安全写入。
- **Beta**：Steam 更新或游戏文件变化时，可以先保存新文件记录；需要时生成测试准备包，进游戏验证后再确认新版本。
- 项目状态围绕原始备份、准备包和写入记录组织。

## App 使用流程

1. 打开或创建项目目录。
2. 设置 FH6 安装目录。
3. 在文件校验里点击“创建原始备份”。
4. 导入音乐到 `sources/`。
5. 在播放列表里把自定义歌曲分配到目标电台和 FreeRoam/Event 列表。
6. 在替换编辑器里运行音频分析，确认 TrackDrop、PostDrop、TrackLoop、PostLoop 时间点。
7. 生成准备包。
8. 点击“写入游戏”。
9. **Beta**：如果 Steam 更新了游戏文件，按文件校验里的路线保存新文件记录、生成测试准备包、进游戏验证并确认新版本；失败时可以放弃新文件或写回原始备份。这个流程仍在打磨，建议只在愿意手动复核文件状态时使用。

语言设置也走准备包和写入游戏流程。比如想保留 EN 语音但显示 CHS 文本，选择 `source=CHS`、`target=EN`，生成准备包后写入游戏。

## AI 选点功能

FH Radio Studio 可以为每首自定义歌曲生成 **AI 时间点候选**，帮助你把歌曲放进 FH6 原本的电台结构里，而不是只从头播放到尾。AI 会分析波形、节拍、段落结构和循环相似度，然后给出 6 个需要确认的时间点：

- `TrackDrop`：比赛、漫游或电台切入时最适合进入主歌/副歌的位置。
- `PostDrop`：赛后或事件结束后适合切入的段落。
- `TrackLoopStart` / `TrackLoopEnd`：常规播放循环段。
- `PostLoopStart` / `PostLoopEnd`：赛后/过渡场景使用的循环段。

在 App 里，推荐流程是：

1. 把歌曲导入项目歌曲池，或从塞壬唱片导入。
2. 打开“替换编辑器”，选择目标歌曲。
3. 如果提示 AI 环境未就绪，先在工具链/AI 环境面板里同步环境和模型缓存。
4. 点击音频分析，等待波形、BPM、段落、候选点和置信度刷新。
5. 逐组试听 AI 候选，必要时手动微调。
6. 确认并保存 6 个时间点；之后生成准备包会使用这些已确认时间点。

AI 只负责提出候选，不会替你直接写入游戏。置信度低或 Provider 降级时，App 会继续给出可用结果，但仍建议你听过循环点和切入点后再确认。产品质量目标是 `local-heavy` 档位；它会使用更完整的本地分析链路，速度和下载体积也会更高。

## CLI 常用入口

所有 Python 命令都通过 `uv` 运行。默认 Python 版本是 3.12。

App 是推荐入口；CLI 主要用于调试、自动化和开发验证。常用入口如下。

检查 FH6 目录和当前状态：

```powershell
uv run fh-radio-studio probe --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6"
uv run fh-radio-studio status --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6" --radio 4 --source CHS --target EN --json
```

安装或修复核心音频工具：

```powershell
uv run fh-radio-studio install-tools --force
uv run fh-radio-studio check-tools
```

分析音频：

```powershell
uv run fh-radio-studio analyze-audio ".\music\01 - Example.flac" --profile local-heavy --json
```

创建原始备份、生成准备包、写入游戏这些完整流程建议在 App 里完成；开发者需要命令行合同时看 `docs/development.md`。

## AI 分析档位

可用 profile：

- **中杯**（`local-base`）：轻量兜底档，只使用基础 MIR 能力；`analyze-audio` 默认走它，避免一上来同步大模型。
- **大杯**（`local-deep`）：启用 Beat This、SongFormer、MERT，适合大多数需要 AI 辅助选点的歌曲。
- **超大杯**（`local-heavy`）：在大杯基础上启用 Demucs 做更完整的本地分析，是产品质量目标。

深度 AI 依赖通过 `pyproject.toml` 的 Dependency Groups 管理。Torch 使用 `torch-cpu` / `torch-cu128` extras，App 的 `UvRuntime` 会按机器环境选择。

## 开发环境

基础要求：

- Windows 桌面环境。
- Flutter SDK，当前 App 使用 Dart SDK `^3.10.7`。
- `uv`。
- FH6 PC 安装目录或测试 fixture。

初始化 App：

```powershell
cd app
flutter pub get
```

运行 App：

```powershell
cd app
flutter run -d windows
```

如果在 agent-managed shell 里 Windows build 卡在 MSBuild/C++ 阶段，可先设置：

```powershell
$env:TrackFileAccess = "false"
```

运行常用检查：

```powershell
uv run --locked pre-commit run --all-files
uv run python -m compileall backend tools test
uv run pytest test/test_cli_mock_game.py test/test_ai_timepoints.py

cd app
flutter analyze
flutter test
```

安装本地提交钩子：

```powershell
uv run --locked pre-commit install
```

如果 Flutter test 在本机 loopback 端口加载阶段失败，确保代理绕过 localhost：

```powershell
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = "localhost,127.0.0.1,::1"
```

## 打包发布

Windows release 从仓库根目录构建：

```powershell
.\tools\build_release.ps1 -CleanBuild
```

release 包会准备离线 uv runtime、Python toolchain、wheelhouse 和核心音频工具；产物写入 `dist/`。更多细节见 `docs/development.md`。

GitHub Actions 也会自动发版：`main` 可以保持当前版本的 RC 号，比如 `0.1.0-rc.1`，但 `main` 仍视为开发分支，会显示 build commit 信息。只有真正的 release branch 才隐藏 build commit：规范是 `release/v<major>.<minor>.<patch>`，例如 `release/v0.1.0`；如果需要按 RC 单独切分，也可以用 `release/v<major>.<minor>.<patch>-rc.<n>`，例如 `release/v0.1.0-rc.1`。推送匹配的 `v0.1.0-rc.1` tag 后，Release workflow 会先跑 Python/Flutter 测试，再构建 Windows zip，并把 zip 和 `.sha256` 上传到 GitHub Release。如果版本带 build metadata（如 `0.1.0-rc.1+7`），可以使用 `v0.1.0-rc.1` 或 `v0.1.0-rc.1+7`。

## 重要限制

- 只面向 PC 版 FH6 文件结构，不支持主机端。
- 只能替换/重排现有电台槽位，不承诺真正新增 FH6 曲目。
- AI 只生成候选，最终时间点仍需要用户试听并确认。
- 不处理 DJ 语音替换。
- 写入游戏前请关闭 FH6。

## 文档入口

- `docs/development.md`：公开开发文档，覆盖本地环境、CLI/App 工作流、测试和 release 构建。
