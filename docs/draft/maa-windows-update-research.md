# MAA Windows 增量更新调研草稿

## 背景

这份草稿整理 MaaAssistantArknights（MAA）在 Windows 桌面端的增量更新做法，并评估它对 Forza Horizon Radio Studio 的参考价值。

调研对象：

- MAA 主仓库：<https://github.com/MaaAssistantArknights/MaaAssistantArknights>
- MAA OTA/镜像发布仓库：<https://github.com/MaaAssistantArknights/MaaRelease>
- 重点文件：
  - `.github/workflows/release-ota.yml`
  - `.github/workflows/release-nightly-ota.yml`
  - `.github/workflows/release-package-distribution.yml`
  - `tools/OTAPacker/zipota.sh`
  - `tools/OTAPacker/ziplist.sh`
  - `src/MaaWpfGui/Services/PendingUpdateApplier.cs`
  - `src/MaaUpdater/main.cpp`
  - `src/MaaWpfGui/ViewModels/Dialogs/VersionUpdateDialogViewModel.cs`

## 结论概览

MAA Windows 更新方案不是 MSIX、Velopack 或传统安装器差分，而是一套自研的文件级 OTA 更新系统：

```text
完整包: MAA-v6.10.7-win-x64.zip
增量包: MAAComponent-OTA-v6.10.6_v6.10.7-win-x64.zip
更新器: MAA.Updater.exe
```

它的 OTA 包不是二进制补丁，而是“新版完整包减去与旧版相同的文件”之后得到的 zip。客户端解压 OTA 后，把新增/变化文件移动到安装目录，并根据 `removelist.txt` 删除旧版遗留文件。

这个设计适合 Flutter Windows 桌面应用借鉴，因为 Flutter release 产物本质上也是一组普通 Windows 文件：

```text
app.exe
flutter_windows.dll
data/
*.dll
runtime/
toolchain/
tools/
```

Windows 运行中不能可靠覆盖正在加载的 exe/dll，所以 MAA 使用独立的 `MAA.Updater.exe` 等主程序退出后替换文件。

## MAA 的包结构

MAA 发布时主要有两类 Windows 包：

- 完整包：`MAA-{VERSION}-win-{ARCH}.zip`
- OTA 包：`MAAComponent-OTA-{FROM}_{TO}-win-{ARCH}.zip`

示例：

```text
MAA-v6.10.7-win-x64.zip
MAAComponent-OTA-v6.10.6_v6.10.7-win-x64.zip
```

从 MaaRelease 当前 release 看，完整包体积约 250 MiB，而相邻版本 OTA 包可能只有约 5 MiB。收益来自“只分发变动文件”，不是来自复杂的二进制 diff。

## OTA 包如何生成

MAA 的 OTA 生成发生在 GitHub Actions 中。`release-ota.yml` 会下载最新完整包和若干历史完整包，然后调用 `tools/OTAPacker/build.sh` 和 `tools/OTAPacker/zipota.sh`。

核心逻辑：

1. 列出旧版 zip 里的文件及 CRC。
2. 列出新版 zip 里的文件及 CRC。
3. 找出“路径相同且 CRC 相同”的文件。
4. 复制新版完整 zip 为 OTA 输出 zip。
5. 从 OTA zip 中删除所有相同文件。
6. 找出旧版存在、新版不存在的文件，写入 `removelist.txt`。
7. 把 `removelist.txt` 和 `filelist.txt` 放进 OTA zip。

简化后可以理解为：

```text
ota.zip = new.zip - unchanged_files(old.zip, new.zip) + removelist.txt
```

它的 `zipota.sh` 关键行为是：

```bash
from_list="$(ziplist.sh "$from_zip" | sort)"
to_list="$(ziplist.sh "$to_zip" | sort)"
comm_list="$(comm -12 <(echo "$from_list") <(echo "$to_list"))"

cp -v "$to_zip" "$out_zip"
echo "$comm_list" | cut -d\  -f2- | xargs zip --delete "$out_zip"

comm -23 <(echo "$from_fn") <(echo "$to_fn") > "$tmpdir"/removelist.txt
zip -X -r -j "$out_zip" "$tmpdir"/removelist.txt "$tmpdir"/filelist.txt
```

`ziplist.sh` 用 `zipinfo` 读取 central directory，提取文件路径和 CRC。也就是说，只要文件内容变化，CRC 不同，该文件就会留在 OTA 包里。

## 客户端如何选择更新包

MAA 客户端检查更新时会请求 MAA API 或 MirrorChyan：

- GitHub/MAA API 路径会读取版本摘要和版本详情。
- MirrorChyan 路径会按当前版本、系统、架构、channel 请求可下载包。

客户端优先找匹配当前版本到目标版本的 OTA：

```text
当前版本: v6.10.6
目标版本: v6.10.7
目标包名包含: MAAComponent-OTA-v6.10.6_v6.10.7-win-x64.zip
```

如果找不到 OTA，但找到了完整包，则回退到完整包更新。MAA 对完整包更新会提示用户确认，因为完整包替换范围更大。

## 客户端如何安装更新

MAA 下载更新包后，不会立刻覆盖当前运行程序。它把“待安装包路径”和“目标版本”写入配置。

下次启动早期，`PendingUpdateApplier` 会检测是否存在 pending update：

```text
启动
  -> 检查 pending update
  -> 解压到 NewVersionExtract
  -> 判断是 OTA 还是完整包
  -> 能安全进程内应用则直接移动 resource 文件
  -> 涉及 exe/dll/runtime 等敏感路径则交给 MAA.Updater.exe
  -> 主程序退出
  -> updater 等待主进程退出并替换文件
  -> 写入成功/失败状态
  -> 重启 MAA.exe
```

MAA 对 OTA 做了一个小优化：如果 OTA 只影响 `resource/`，主程序可以直接进程内替换；如果 OTA 影响 runtime-sensitive path，则必须交给外部 updater。

## 外部更新器职责

`MAA.Updater.exe` 是 C++ 写的独立程序，并且在 CMake 中使用静态 CRT：

```text
Static CRT - no runtime DLL dependency, updater must survive MAA's own runtime being replaced
```

它的职责是：

- 等待主进程退出。
- 读取更新计划 JSON。
- 删除或备份旧文件。
- 把解压目录里的文件移动到安装目录。
- 删除更新包。
- 写成功或失败状态文件。
- 尝试重新启动主程序。

更新计划大致是：

```json
{
  "packageType": "full|ota",
  "removeList": ["rel/path", "..."],
  "moveList": ["rel/path", "..."]
}
```

外部 updater 还做了路径安全检查：所有路径都必须解析在安装根目录之下，避免恶意包用 `../` 或绝对路径写出安装目录。

## 完整包更新时保留什么

完整包更新会替换大部分安装目录内容，但保留用户数据和更新器本身。MAA 当前保留项包括：

```text
achievement
background
cache
config
data
debug
MAA.Updater.exe
```

旧文件会移动到 `.old`。如果替换失败，会通过状态文件提示用户进行手动恢复。

## 历史版本多时怎么办

MAA 不是生成所有版本两两差分包，而是每次新版本发布时生成“多个旧版本到最新版本”的 OTA：

```text
v6.10.4 -> v6.10.7
v6.10.5 -> v6.10.7
v6.10.6 -> v6.10.7
```

因此复杂度是 O(N)，不是 O(N²)。

它的 workflow 有 `limit` 参数，只取有限数量的历史 release。工程上通常这样控制：

- 只支持最近 N 个版本 OTA。
- 太老版本回退完整包。
- stable 生成较多 OTA，beta/nightly 少生成或只生成相邻版本 OTA。
- 大资源、runtime、工具链拆成独立包，用 hash/version 判断是否需要下载。
- CDN 或 release 存储定期清理旧 OTA。

对我们来说，不建议一开始兼容几十个历史版本。更现实的策略是：

```text
最近 5-10 个版本: OTA
更老版本: 完整包
runtime/toolchain/audio tools: 独立包，按 hash 复用
```

## 对本项目的启发

Forza Horizon Radio Studio 是 Flutter Windows + Python runtime + uv toolchain + 音频工具链的桌面应用。和 MAA 相比，我们的更新难点不只是 Flutter app 本体，还包括这些大块内容：

```text
runtime/
toolchain/
tools/audio/ffmpeg/
tools/audio/vgmstream/
tools/audio/fmod/
data/cache/config/debug 等用户数据
```

建议采用分层更新：

```text
app 包: Flutter exe/dll/data
runtime 包: Python runtime + wheels
toolchain 包: uv + uv cache
audio-tools 包: ffmpeg/vgmstream/fsbankcl
optional-assets 包: 预置资源、模型、模板
```

每个包都在 manifest 中声明：

```json
{
  "version": "1.4.0",
  "channel": "stable",
  "arch": "x64",
  "packages": [
    {
      "id": "app",
      "version": "1.4.0",
      "url": "https://example/app-1.4.0-win-x64.zip",
      "sha256": "...",
      "size": 123456
    },
    {
      "id": "runtime",
      "version": "2026.05.25",
      "url": "https://example/runtime-2026.05.25-win-x64.zip",
      "sha256": "...",
      "size": 123456
    }
  ]
}
```

如果 `runtime` 没变，就不下载它。这样比每次对整个安装目录做 OTA 更稳。

## 推荐落地路线

第一阶段先做完整包更新：

- 发布完整 zip。
- 应用检查 manifest。
- 下载完整包。
- 写 pending update。
- 重启后由独立 updater 替换安装目录。
- 保留 `config/`、`data/`、`debug/`、用户导入资产和 updater。

第二阶段加入 MAA 风格文件级 OTA：

- CI 保存最新完整包和最近 N 个历史完整包。
- 生成 `from -> latest` 的 OTA zip。
- OTA 包包含变更文件、`removelist.txt`、`filelist.txt`。
- 客户端优先下载精确匹配当前版本的 OTA。
- 找不到 OTA 时回退完整包。

第三阶段拆大资源包：

- `runtime`、`toolchain`、`audio-tools` 独立版本化。
- 这些包按 hash/version 复用。
- 主程序 OTA 只覆盖 Flutter app 本体和轻量资源。

## 需要比 MAA 更谨慎的地方

MAA 调研路径里没有看到独立的 SHA-256 或签名校验作为客户端更新安装前的强校验。我们如果实现，建议补上：

- manifest 带 `sha256`。
- manifest 本身签名，或使用 HTTPS + GitHub Release API + 固定发布者信任边界。
- 下载后先校验 hash，再解压。
- 解压时拒绝绝对路径和 `..`。
- 更新计划只允许覆盖安装目录内的相对路径。
- 外部 updater 使用静态链接或尽量少依赖被替换目录里的 DLL。
- 保留可回滚备份，失败时不要清掉恢复现场。

## 可以直接借鉴的命名

```text
FHRadioStudio-v1.4.0-win-x64.zip
FHRadioStudioComponent-OTA-v1.3.2_v1.4.0-win-x64.zip
FHRadioStudio.Updater.exe
```

也可以更短：

```text
fh-radio-studio-v1.4.0-win-x64.zip
fh-radio-studio-ota-v1.3.2_v1.4.0-win-x64.zip
fh-radio-studio-updater.exe
```

建议使用小写短名，便于脚本和 CDN 路径处理。

## 初步方案草图

```text
CI release
  -> flutter build windows
  -> prepare release runtime/toolchain/audio tools
  -> assemble full package
  -> compare recent historical full packages
  -> generate OTA zips
  -> generate release manifest
  -> upload assets

App startup/manual check
  -> GET manifest
  -> compare app version/channel/arch/package ids
  -> choose exact OTA if available
  -> fallback full package if OTA missing
  -> download to temp
  -> verify sha256
  -> register pending update
  -> ask restart or auto restart when idle

Updater
  -> wait main app exit
  -> validate update plan
  -> backup changed paths
  -> apply file moves/removals
  -> write status
  -> restart app
```

## 开放问题

- 安装位置是否固定在 `%LOCALAPPDATA%`，还是允许 portable 解压运行？
- 用户数据目录是否要继续放安装目录，还是迁移到 `%APPDATA%` / `%LOCALAPPDATA%`？
- 是否需要支持离线更新包拖入应用？
- 是否需要 nightly/beta/stable 多 channel 更新？
- 是否要做 rollback UI，还是只保留 `.old` 供手动恢复？
- 是否要用现成框架 Velopack 替代自研外部 updater？

当前倾向：先做“完整包 + updater + manifest/hash 校验”，再加入最近 5-10 个版本的文件级 OTA；大体结构借鉴 MAA，但补齐 hash/signature 校验和本项目的 runtime/toolchain 分包。
