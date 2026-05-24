# Handoff: FH Radio Studio — FH6 电台修改工具

> 桌面应用，用于修改《极限竞速：地平线 6》(Forza Horizon 6, "FH6") 游戏内电台。

---

## Overview

FH Radio Studio 是一款 **PC 桌面工具**，让玩家替换 FH6 游戏内电台的歌曲、编辑电台播放列表、并精细调整每首替换歌曲在比赛中的播放时间点（drop / loop）。

应用要解决的三个核心场景：

- **场景 A — 替换电台中的某首歌**：拖入用户音乐 → 自动响度归一化 → AI 给 6 个时间点候选 → 用户预听确认 → 写入游戏文件。
- **场景 B — 编辑电台播放列表**：在电台之间拖拽歌曲、删除、复制；不改音频，只改 XML。
- **场景 C — 微调已替换歌曲的循环点**：列出已替换的曲目，重新进入时间点编辑界面。

完整产品需求见 `original-design-brief.md`。

---

## About the Design Files

`design/` 目录下的所有文件都是 **HTML/React 设计参考**，不是要直接发布的生产代码。它们是一份**高保真可交互原型**，展示：

- 视觉系统（颜色、字体、间距、阴影、圆角）
- 各屏幕的布局、信息密度、组件构成
- 关键交互（侧栏切换、tweaks 面板、波形编辑、拖拽、modal）
- 文案（中文为主，部分技术术语保留英文）

**任务是：在 Flutter 工程中重新实现这些设计**，沿用 Flutter 的生态（Material 3 或 Cupertino + 自定义主题、`flutter_riverpod` / `bloc` 等）。HTML 原型只是参考，**不要逐行翻译 CSS**——而是提取设计 token，按 Flutter 的方式重建。

> 如果团队最终选了其他栈（Tauri + React、Electron 等），同样的原则适用：以设计 token 和组件清单为准。

---

## Fidelity

**高保真 (hi-fi)**。所有颜色、字号、间距、圆角都是终稿值——开发请按下方 Design Tokens 部分照搬，不要"差不多就行"。文案、图标位置、交互细节也都是有意的设计决策。

唯一例外：原型里的图标用的是 inline SVG（见 `design/components/ui.jsx` 中的 `<Icon>`），Flutter 端可换成 `material_symbols_icons` 或 `lucide_icons` 包里的对应字形。

---

## Tech Stack Recommendation (Flutter)

| 关注点 | 推荐 |
| --- | --- |
| UI 框架 | Flutter 3.x，**自定义 `ThemeData`** 不要用默认 Material 配色 |
| 字体 | `Geist` (sans) + `Geist Mono` (mono) + `Noto Sans SC` (中文 fallback)。用 `google_fonts` 包或直接打包字体文件 |
| 状态管理 | `flutter_riverpod`（推荐）或 `flutter_bloc`。状态量见下方 *State Management* 一节 |
| 路由 | `go_router`，配合下方 *Screens* 一节的路由表 |
| 波形渲染 | 自绘 `CustomPainter`（推荐，性能可控），或 `just_waveform` 包 |
| 拖拽 | `Draggable` + `DragTarget`（Flutter 内置） |
| 音频播放 | `just_audio` |
| 文件 IO | `path_provider` + `file_picker` |
| FMOD bank 操作 | 通过 `dart:ffi` 调 FMOD Studio API，或 spawn 一个 Python 子进程跑 `fmodtool.py` |
| AI 时间点分析 | 后端用 Python（librosa + 自定义模型）通过本地 HTTP / stdin-stdout 进程间通信 |
| 平台 | Windows + macOS 桌面（FH6 仅 PC，所以不需要移动） |

> 关于 FMOD：FMOD 的 C SDK 没有官方 Dart binding。最干净的做法是把 FMOD 调用 + AI 分析都放进一个 sidecar Python 进程，Flutter UI 通过 stdin/stdout JSON 通信。这也允许后续替换 AI 模型而不动 UI。

---

## Application Shell

应用整体是经典的 **三段式桌面布局**：

```
┌──────────────────────────────────────────────────────┐
│  TitleBar  · brand · project pill · status · ⌘K     │ ← 44px
├────────────┬─────────────────────────────────────────┤
│  Sidebar   │  Main content (scrollable)              │
│  220px     │                                         │
│  - 概览     │                                         │
│  - 自建歌曲  │                                         │
│  - 播放列表  │                                         │
│  - 备份     │                                         │
│  - 系统架构  │                                         │
│            │                                         │
│  [settings]│                                         │
│  v0.4.2    │                                         │
└────────────┴─────────────────────────────────────────┘
```

`navStyle` tweak 可切换为顶部 tab 布局（rail → 220px 左栏；tabs → 顶部 44px 横向 tab 条）。Flutter 实现：`LayoutBuilder` + 条件渲染即可。

**TitleBar 内容**：
- 左侧：mac 红黄绿交通灯（macOS 才显示，Windows 用自绘按钮）+ "FH Radio Studio · FH6 电台修改工具"
- 项目 pill：当前打开的 `.rmod.json` 文件名 + "已保存" 状态
- 右侧：FMOD 连接状态（绿点）+ 游戏运行状态（黄点）+ 备份空间使用 + 命令面板按钮（⌘K）

**Sidebar 内容**：
- 概览 / 自建歌曲 / 播放列表 / 备份 / 系统架构 五个主页
- 底部：设置、版本号 (`FH Radio Studio 0.4.2`, `FH6 build 2.317.41.0`)
- **Active 高亮**：左侧 3px 强调色竖条 + 14% 强调色背景 + 1px 强调色描边 + 字体加粗 + 图标染色

---

## Screens / Views

### 0. Boot / Project Picker (`screens/project-picker.jsx`)

启动屏。两张大卡片（"新建工程" / "打开工程"）+ 下方最近工程列表。设计风格类似 VS Code / Cursor 的 Welcome 页。

- **Logo**：30×30 强调色方块，内嵌一个旋转 45° 的对勾边框
- **Recent rows**：游戏代号方块（"FH6"）+ 工程名 + 路径（mono 字体）+ 最近修改时间

### 1. Dashboard (`screens/dashboard.jsx`)

总览页。顶部一行 stat cards（已替换数 / 已使用电台 / 备份大小 等），下方是 7 个电台的列表，每行包含电台代号 + 名称 + 已替换槽位的进度。

### 2. Custom Pool (`screens/custom-pool.jsx`) — 用户的自建歌曲池

7 列表格：封面 / 标题+艺人 / 来源文件 / chips（响度归一化、采样率） / 确认进度 / 添加时间 / actions。点击行进入 Replace Editor (#3)。

### 3. Replace Editor (`screens/replace.jsx`) — **场景 A 主界面，最重要**

布局：左侧主区 + 右侧 340px 固定边栏。

**主区从上到下**：
1. **Target picker**（顶部 pill 卡片）：显示当前编辑的歌曲；点击展开 popover 切换到其他草稿或从电台直接选 slot
2. **Progress strip**：横向四宫格，展示 TD / PD / TL / PL 四组的状态（`pending → suggested → confirmed`）和当前值
3. **Waveform card**：toolbar（波形/频谱/+节拍 segmented）+ 主波形（带 6 个时间点 marker、循环段阴影、playhead）+ 缩略波形（zoom window）
4. **Transport bar**：播放/暂停、当前时间码、BPM、LUFS、Space 快捷键提示
5. **AI confidence banner**：黄色横幅，提醒置信度不足的字段
6. **四个 Time Group 卡片**（TD / TL / PD / PL，按这个顺序）：每个卡片显示 top-3 候选 + 选中态 + "试听 / 试听拼接" 按钮 + 1拍微调 + 确认按钮

**右侧边栏**：
- AI 分析卡（置信度、采样率、BPM、节拍数、各组 top score）
- 确认进度卡（4 个 checkbox + 主 CTA "写入游戏 (pre-flight)"）
- 快捷键参考卡

**关键设计决策**：
- 波形是**信息密度最高的元素**，所有 6 个时间点叠在同一波形上，让用户一眼看到相对位置
- 时间组卡片有四种 accent color：TD = 强调色，PD = 紫色，TL = 蓝色，PL = 橙色——marker、loop shade、卡片 badge 都用对应色
- "试听拼接"是核心交互：点击后从 A 前 2 秒开始播 → 跳到 B → 再播 2 秒 → 循环 3 次

### 4. Playlist Editor (`screens/playlist.jsx`) — 场景 B

电台并排显示（grid auto-fit minmax(260px, 1fr)），每个电台是一列，列内显示该电台的歌曲列表，**用户可在电台之间拖拽歌曲**。

下方有 "Pool strip"，即未分配的自建歌曲池——也是可拖入电台的源头。

`pl-track[data-modded="true"]` 表示这首歌是用户替换过的，用强调色高亮。`pl-track[data-locked="true"]` 表示原版曲目（半透明，不可拖）。

**拖拽行为**：
- 拖入原版电台 → 该电台会被"牺牲"，弹警告（黄色 banner）
- 拖入自建电台 → 直接添加
- 拖回 pool → 从该电台移除

### 5. Backups (`screens/backups.jsx`)

三块：
1. 游戏文件备份（自动）：每次写入前的快照列表
2. 配置文件备份（`.rmod.json`）：本地工程文件历史
3. 手动快照：用户主动建立的备份

每行：时间戳（mono） + 描述 + 大小 + 操作（恢复 / 删除）。

### 6. Architecture (`screens/architecture.jsx`)

文档型页面，给用户看的"应用如何工作"图。三层（UI / Core / FS）+ 数据流箭头 + Scenario A/B/C 的 step-by-step flow card。

可在 v1 之后再实现，对 MVP 不是关键。

### 7. Pre-flight Modal (`screens/preflight.jsx`) — **不可逆操作的最后一道闸**

写入游戏前必弹的 modal：
- 顶部：橙色 eyebrow "确认写入 · 此操作将修改游戏文件"
- 主体：
  - 6 个时间点的精确值（秒 + 采样数换算后的整数），mono 表格
  - 将被写入的文件路径（红色行）+ 将被备份的文件路径（绿色行）
  - 三个必勾 checkbox：① 已关闭 DJ ② 已退出游戏 ③ 理解此操作不可逆
- 底部：取消 / 确认写入（必须勾完才亮）

---

## Design Tokens

### Colors — Light Theme (Default)

| Token | Value | 用途 |
| --- | --- | --- |
| `--bg` | `#f7f7f8` | 应用底色 |
| `--panel` | `#ffffff` | 卡片背景 |
| `--raised` | `#f3f3f5` | 凸起表面（按钮 / input 背景） |
| `--hover` | `#ececef` | hover 态背景 |
| `--border` | `#e5e5ea` | 默认描边 |
| `--border-2` | `#d8d8de` | 次级描边 |
| `--border-strong` | `#b8b8c0` | 强描边 / focus ring |
| `--fg` | `#18181b` | 主文字 |
| `--fg-2` | `#52525b` | 次要文字 |
| `--fg-3` | `#71717a` | 辅助文字 |
| `--fg-4` | `#a1a1aa` | 最浅文字 |

### Colors — Dark Theme

| Token | Value |
| --- | --- |
| `--bg` | `#0a0a0b` |
| `--panel` | `#111113` |
| `--raised` | `#17171a` |
| `--hover` | `#1d1d21` |
| `--border` | `#232328` |
| `--fg` | `#ededed` |
| `--fg-2` | `#a1a1a6` |
| `--fg-3` | `#6b6b72` |

### Semantic Colors

| Token | Light | Dark |
| --- | --- | --- |
| `--warn` | `oklch(0.55 0.16 75)` (深琥珀) | `oklch(0.86 0.16 90)` |
| `--warn-bg` | `oklch(0.95 0.06 85)` | `oklch(0.86 0.16 90 / 0.10)` |
| `--danger` | `oklch(0.55 0.20 25)` (深红) | `oklch(0.68 0.22 25)` |
| `--danger-bg` | `oklch(0.96 0.05 25)` | `oklch(0.68 0.22 25 / 0.10)` |
| `--info` | `oklch(0.50 0.15 230)` | 同 |

### Accents (4 options, user-tweakable)

| Name | Light | Dark |
| --- | --- | --- |
| `lime` (默认) | `oklch(0.62 0.18 145)` ≈ `#3fa55c` | `oklch(0.86 0.18 130)` |
| `cyan` | `oklch(0.58 0.13 210)` ≈ `#3a92b8` | 同 |
| `orange` | `oklch(0.62 0.18 50)` ≈ `#d97333` | 同 |
| `magenta` | `oklch(0.55 0.22 340)` ≈ `#b04895` | 同 |

每个 accent 派生：
- `--accent-2`: accent @ 12% opacity（用作 chip / badge 背景）
- `--accent-3`: accent @ 35% opacity（用作描边 / focus ring）
- `--on-accent`: accent 上的文字色，浅色主题为 `#ffffff`，深色为 `#0a0a0b`

### Time Group Accent Colors

四个时间组各有独立的 accent，**不要替换**——这是信息编码：

| Group | Color | OKLCH |
| --- | --- | --- |
| TD (TrackDrop) | 用主 accent | — |
| PD (PostDrop) | 紫 | `oklch(0.52 0.18 270)` |
| TL (TrackLoop) | 蓝 | `oklch(0.55 0.15 210)` |
| PL (PostLoop) | 橙 | `oklch(0.60 0.18 30)` |

### Typography

| Role | Font Stack | 用途 |
| --- | --- | --- |
| Sans | `"Geist", "Noto Sans SC", system-ui, sans-serif` | UI 主字体 |
| Mono | `"Geist Mono", "JetBrains Mono", ui-monospace, monospace` | 时间码、采样数、文件路径、技术 label |

字号系统（px，1.5 line-height 默认）：

| Size | 用途 |
| --- | --- |
| 10–10.5 | 极小 mono label（small caps style，字距 0.10–0.12em） |
| 11–11.5 | chip 文字、tabular data |
| 12–12.5 | 次要 UI 文字、按钮 |
| 13 | 主要 UI 文字（body） |
| 13.5 | 列表行标题 |
| 14 | 卡片标题、modal body |
| 16 | empty state 标题 |
| 20 | modal H2 |
| 22 | boot logo |
| 24 | 页面 H1（字距 -0.01em） |
| 26 | stat card value（字距 -0.02em） |

Font weight：300/400 (regular) / 500 (medium) / 600 (semibold) / 700 (bold)。

### Spacing

无固定 8pt 网格。常用 padding / gap：
- 卡片内 padding：14px / 18px
- 行间 gap：4px / 6px / 8px / 10px / 12px / 14px / 16px / 18px
- 页面外边距：`page` = max-width 1240px + padding 36px 40px 96px
- 页面 narrow = 920px / wide = 1400px

### Border Radius

| Token | Value | 用途 |
| --- | --- | --- |
| `--r-xs` | 4px | tag / kbd |
| `--r-sm` | 6px | button / input / chip / 列表行 |
| `--r-md` | 8px | banner |
| `--r-lg` | 12px | 主卡片 |
| `--r-xl` | 16px | modal |

圆形：50%（avatar、点状指示器、播放按钮 38×38）。

### Shadows

- 弹出层（popover）：`0 16px 40px rgba(20,20,30,0.12), 0 4px 12px rgba(20,20,30,0.06)`
- Modal：`0 30px 60px rgba(20,20,30,0.18), 0 8px 20px rgba(20,20,30,0.08)`
- Modal backdrop：`rgba(20,20,30,0.35)` + `backdrop-filter: blur(4px)`

---

## Key Components

### Button

```
.btn        height 32px, padding 0 14px, radius 6px, font 12.5px
.btn-sm     height 26px, padding 0 10px, font 11.5px
.btn-lg     height 38px, padding 0 18px, font 13px
.btn-icon   width 32px, padding 0 (方按钮)

.btn-primary  accent 填充 + on-accent 文字 + 加粗
.btn-ghost    透明 + 透明描边 + fg-2 文字
.btn-danger   danger 文字（hover 时填充 danger-bg）
```

Hover：`background: var(--hover); border-color: var(--border-strong);`
Active：`transform: translateY(0.5px);`
Disabled：`opacity: 0.4;`

### Input

```
height 32px, padding 0 12px, radius 6px
background var(--raised), border 1px var(--border)
focus: border-color var(--accent), box-shadow 0 0 0 3px var(--accent-2)
```

### Chip / Badge

```
display inline-flex, gap 6px, padding 2px 8px, radius 999px
background var(--raised), border 1px var(--border)
font: mono 11px, color var(--fg-2)

modifiers: chip-accent / chip-warn / chip-danger / chip-muted
所有 modifier 都改 text + border + bg + 内部 dot 色
```

### Nav Item (Sidebar)

```
default:    padding 8px 10px 8px 13px, fg-2, no bg
hover:      bg var(--hover), color var(--fg)
active:     bg color-mix(in oklab, var(--accent) 14%, var(--raised))
            color var(--fg), font-weight 600
            inset 0 0 0 1px box-shadow @ 35% accent
            ::before 3px 宽强调色竖条（top 7, bottom 7, left 3）
            icon → accent color
```

### Waveform (核心组件，见 `components/waveform.jsx`)

三层结构：

```
┌─────────────────────────────────────────────────────┐
│   [TD▼]                  [PL-A▼]                    │ ← markers (彩色竖条 + flag)
│   ███████ │█│  ▓▓▓▓▓░░░░░░░│█│ ████ ▓▓▓ ░░░         │
│   ██████ ▓█▓  ▓▓▓▓▓░░░░░░░░█  ████ ▓▓▓ ░░░         │ ← waveform (双向条形)
│   ▓▓▓▓▓▓ ▓█▓  ▓▓▓▓▓░░░░░░░░█  ████ ▓▓▓ ░░░         │
│         ░░░░░░░░░░░░░░ (loop shade @ 10% opacity)  │
├─────────────────────────────────────────────────────┤
│ INTRO   VERSE  CHORUS    BRIDGE    OUTRO            │ ← segments (24px 高彩色条)
├─────────────────────────────────────────────────────┤
│ 0:00      1:00     2:00     3:00     3:34          │ ← time axis (mono 10px)
└─────────────────────────────────────────────────────┘
│  缩略波形 + window (拖动 / 缩放)                       │ ← 56px zoom strip
└─────────────────────────────────────────────────────┘
```

**Marker 视觉**：
- 2px 宽竖条 + 顶部 flag（"TD" / "TL-A" 等 mono label）
- TD/PD = 实心，TL/PL 用对应组色

**Loop shade**：A 和 B marker 之间填一层 10% opacity 的组色

**Playhead**：白色 1px 竖线 + 顶部小三角

Flutter 实现建议：单个 `CustomPainter`，所有 layer 在 `paint()` 里画。把 `beats`、`segments`、`markers` 作为 ValueNotifier 传入。

### Time Group Card (PointGroup / LoopGroup)

每个时间组卡片：

```
┌─────────────────────────────────────────────────────┐
│  [TD]  TrackDrop                       [✓ 已确认]    │
│        比赛开始时的播放起点                            │
├─────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────┐    │
│  │  ①  0:01:08.72  首个 chorus 入口    ████▓ 92% [▶ 试听] [使用]  │ ← cand (selected)
│  │  ②  0:01:30.51  第二段副歌         ███░░ 61% [▶]    [使用]    │
│  │  ③  0:02:48.04  outro 后高音       ██░░░ 45% [▶]    [使用]    │
│  └────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐           │
│  │  微调  当前值  0:01:08.720  [◀ 1拍] [1拍 ▶] (Shift = 1ms)  │
│  └─────────────────────────────────────┘           │
└─────────────────────────────────────────────────────┘
```

**Loop group** (TL / PL) 多一个字段：`bars`（"32 bars"），且"试听"换成"试听拼接"（A→B→A 循环 3 次）。

**低置信度警示**：候选 score < 0.5 时，卡片底部出 `tg-warn` 黄色条："AI 信心不足，建议手动指定"。

### Modal (Pre-flight Checklist)

- 720px 宽，max-height 88vh
- 头部 22px padding，eyebrow + H2 + sub
- body：表格 + checklist
- footer：左侧 mono 状态文字（"将在 23s 内完成"），右侧取消 + 主 CTA
- 主 CTA 在三个 checkbox 全勾且数据校验通过前 disabled

---

## State Management

### App-level state

```dart
// 路由
String route;  // boot | dashboard | pool | playlist | backups | architecture | editor

// Modal
String? modal;  // null | 'preflight'

// Tweaks
String accent;     // 'lime' | 'cyan' | 'orange' | 'magenta'
String navStyle;   // 'rail' | 'tabs'
String theme;      // 'light' | 'dark'

// Replace editor 进入时携带
Track? editingTrack;
```

### Replace Editor state (`screens/replace.jsx`)

```dart
class ReplaceEditorState {
  int tdIdx, pdIdx, tlIdx, plIdx;     // 当前选中的候选 index
  bool tdConfirmed, pdConfirmed, tlConfirmed, plConfirmed;
  bool playing;
  double playhead;     // 秒
  // 派生：allConfirmed = tdC && pdC && tlC && plC
}
```

### AI Result schema (持久化在 `.rmod.json`)

```json
{
  "duration_sec": 214.309,
  "bpm": 128.0,
  "confidence": 0.83,
  "candidates": {
    "td": [{"t": 68.72, "score": 0.92, "why": "首个 chorus 入口"}, ...],
    "pd": [{"t": 148.72, "score": 0.88, "why": "终段 chorus"}, ...],
    "tl": [{"start": 23.01, "end": 118.25, "score": 0.86, "bars": 32}, ...],
    "pl": [{"start": 97.27, "end": 177.27, "score": 0.83, "bars": 24}, ...]
  },
  "beats": [/* number[] */],
  "downbeats": [/* number[] */],
  "segments": [{"start": 0, "end": 23.5, "label": "intro"}, ...]
}
```

### 写入游戏的最终值（pre-flight 显示）

每首歌 6 个数：
- `td` (秒) × 48000 = TrackDrop sample
- `pd` (秒) × 48000 = PostDrop sample
- `tl_start, tl_end` (秒) × 44100 = TrackLoopStart/End sample
- `pl_start, pl_end` (秒) × 44100 = PostLoopStart/End sample

**注意**：td/pd 采样率 48000，loop 采样率 44100，**不能统一**——这是游戏机制。

---

## Interactions & Behavior

### Sidebar navigation

- Click 任意 nav-item → 切换 `route`
- 当 `route === "editor"` 时，sidebar 把 `pool` 项高亮（因为编辑器是从自建歌曲池进入的）
- `navStyle === "tabs"` 时改为顶部 tab，逻辑相同

### Tweaks Panel

右下角浮动面板（可拖动），三个 section：
1. 主题（light / dark radio + accent 颜色 swatches）
2. 布局（rail / tabs radio）
3. 跳转（快速跳到任意 route 的按钮组）

面板可被切换显示/隐藏，状态持久化（HTML 原型里通过 `__edit_mode_set_keys` 协议同步到磁盘；Flutter 端写本地 prefs 即可）。

### Replace Editor 主流程

1. 用户从 Custom Pool 点击一首歌 → 进入 editor，`editingTrack` 设置好
2. AI 已经在导入时跑过，进入时直接显示候选
3. 用户对每组：
   - 看候选列表 → 点 ▶ 试听（单点：从该时间起播 8 秒；循环点：A前2s → B → 跳A → 重复 3 次）
   - 微调（默认 1 拍移动，Shift 改 1ms）
   - 确认 → progress strip 对应格变绿
4. 四组全确认 → 主 CTA 亮起 → 点击进入 Pre-flight
5. Pre-flight 三 checkbox 全勾 → "确认写入" 亮起 → 写入 → 跳到 Backups 页

### Playlist drag-drop

- 自建歌曲行（`pl-track[data-modded]`）：可拖
- 原版歌曲行（`pl-track[data-locked]`）：cursor 改 not-allowed，不可拖
- 拖到原版电台列（`pl-col.builtin`）：放下时弹警告
- 拖回 pool 列（`pl-col.pool-col`）：从该电台移除

Flutter：`LongPressDraggable` + `DragTarget`，搭配 `data-dragover` 视觉态。

### Keyboard Shortcuts (Replace Editor)

| 按键 | 行为 |
| --- | --- |
| `Space` | 播放 / 暂停 |
| `1` / `2` / `…` | 跳到对应段（intro / verse / chorus / …） |
| `Enter` | 确认当前候选 |
| `←` / `→` | 前进 / 后退 1 拍 |
| `Shift + ← / →` | 1 毫秒微调 |
| `⌘ + Z` | 撤销 |

全局：`⌘K` 打开命令面板（v1 之后实现）。

### Animations

- nav-item active 切换：无 transition（即时）
- button hover：`background .12s, border-color .12s`
- target-caret 展开：`transform .15s`
- boot splash 脉动：`pulse 1.2s ease-in-out infinite`
- modal 出现：可加 200ms fade + scale (0.96 → 1)，HTML 原型未实现，Flutter 端推荐加上

---

## Assets

- **字体**：`Geist` + `Geist Mono` + `Noto Sans SC` — 全部 Google Fonts 可获取，建议本地打包以保证离线可用
- **图标**：HTML 原型用 inline SVG（见 `design/components/ui.jsx` 的 `<Icon>` 组件，提供了 ~30 个 stroke 图标如 `dashboard, music, list, shield, arch, play, pause, check, x, folder, settings, command, warn, import, export, zoom-in, zoom-out, skip-back, skip-fwd, arrow-right` 等）。Flutter 端用 `lucide_icons` 或 `material_symbols_icons`，能匹配 90% 的字形
- **游戏 logo / 封面**：原型用 mono 字母（"FH6"、"HOR"、"BLK"、"XS"）做占位，最终发布时若要图片素材需另外提供
- **应用图标**：尚未设计

---

## Files in this Bundle

This archived design handoff lives under `docs/internal/design-handoff/`. It is internal reference material for implementation, not production source.

```
docs/internal/design-handoff/
├── README.md                       ← 本文档
├── original-design-brief.md        ← 用户最初给 Claude 的设计任务 prompt
├── screenshots/                    ← 各屏幕高清截图（直接看，不用跑前端）
│   ├── 01-boot-project-picker.png
│   ├── 02-dashboard.png
│   ├── 03-custom-pool.png
│   ├── 04-replace-editor.png      ← 场景 A 主界面，最重要
│   ├── 05-playlist-editor.png
│   ├── 06-backups.png
│   ├── 07-architecture.png
│   └── 08-preflight-modal.png     ← 写入前确认 modal
└── design/                         ← HTML 原型源码
    ├── index.html                  ← 入口
    ├── styles.css                  ← 所有样式 + tokens
    ├── app.jsx                     ← App shell, 路由, tweaks
    ├── data.jsx                    ← 假数据（电台、曲目、AI 结果）
    ├── tweaks-panel.jsx            ← Tweaks 面板框架（开发可忽略）
    ├── components/
    │   ├── sidebar.jsx             ← Sidebar + TitleBar
    │   ├── ui.jsx                  ← Icon, 通用 primitives
    │   ├── waveform.jsx            ← 波形 + zoom strip
    │   └── time-group.jsx          ← PointGroup + LoopGroup 卡片
    └── screens/
        ├── project-picker.jsx      ← 启动 / 工程选择
        ├── dashboard.jsx           ← 总览
        ├── custom-pool.jsx         ← 自建歌曲池
        ├── replace.jsx             ← Replace Editor (场景 A 主界面)
        ├── playlist.jsx            ← Playlist Editor (场景 B)
        ├── backups.jsx             ← 备份页
        ├── architecture.jsx        ← 系统架构说明页
        └── preflight.jsx           ← 写入前 modal
```

直接打开 `design/index.html` 即可在浏览器看到完整原型。Tweaks 面板（右下角）可切换主题、强调色、导航样式，对应 Flutter 实现里这三个变量都必须做成可配置。

---

## Edge Cases & Risks

最初设计 brief 里点出的风险，复述给开发：

1. **替换的"牺牲一个电台"机制**：一旦替换某电台某槽位，**整个电台都会锁成同一首歌**。UI 必须在替换前明确提示，且 Playlist Editor 里把这种电台标记为 "modded"。
2. **AI 失败时**：任何字段没有 score > 0.5 的候选，要明显提示"AI 信心不足，请手动指定"，但仍允许用户手点。
3. **写入操作不可逆**：必须有 Pre-flight 三确认 + 自动备份。备份页要能一键回滚。
4. **DJ 语音覆盖**：必须在 Pre-flight 里的 checkbox ① 强制提示用户先在游戏设置里关闭电台 DJ。
5. **采样率混用**：td/pd = 48000，loop = 44100。文档里千万别"统一成 48000"——会导致 loop 偏移。Pre-flight 表格里把两个采样率显式列出。
6. **多语言 XML 同步**：场景 B 修改播放列表时，要同时写所有 `RadioInfo_<LANG>.xml` 文件（en / zh-CN / fr / de / es / it / ja / ko / pt-BR / ru）。
7. **游戏正在运行时**：检测到 FH6 进程在运行 → 写入按钮 disabled，提示先退游戏。TitleBar 的"游戏未运行" LED 反映这个状态。

---

## Open Questions for Implementer

- **FMOD bank 读写**：用 FMOD Studio SDK (C) 还是 reverse-engineered Python 库 `python-fmod`？前者需要签 EULA，后者社区维护，质量未知。
- **AI 模型部署**：本地 Python 进程跑 librosa + 自定义 PyTorch 模型？还是用纯 librosa heuristic（beat tracking + structural segmentation）？最初版本建议后者，简单可控。
- **应用图标**：尚未设计，需要 brand 阶段补齐。
- **国际化范围**：原型是中文，需不需要英文版？brief 里没说。

---

## Where to Start

1. 跑通 `design/index.html`，把每个屏幕都点一遍，理解信息架构
2. 在 Flutter 项目里先实现：
   - 设计 token（写一个 `app_theme.dart`）
   - 字体加载
   - Shell（TitleBar + Sidebar + Main 三段布局）
3. 实现两个最关键的屏幕：**Dashboard**（最简单）和 **Replace Editor**（最复杂，能验证大部分组件）
4. 波形组件用 `CustomPainter` 单独做一个 demo，验证 markers + segments + playhead + loop shade 同时叠加的渲染
5. 拖拽：Playlist Editor 是 Drag&Drop 集中地，先用 mock 数据走通一遍
6. 最后接 FMOD 子进程 + AI 进程

祝开发顺利！如有视觉细节疑问，原型源码是 source of truth；如有交互疑问，回到 `original-design-brief.md` 查最初约束。
