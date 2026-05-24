---
name: flutter-visual-qa
description: Project workflow for verifying Flutter UI changes in this repo, including layout polish, screenshots, runtime rendering assertions, Windows desktop runs, and widget/semantics tests. Use when editing Flutter screens/widgets, responding to UI screenshots, investigating spacing/overflow/semantics/rendering errors, or claiming a Flutter UI fix is complete.
---

# Flutter Visual QA

## Core Rule

Do not treat `flutter analyze` or ordinary unit tests as visual verification. For Flutter UI work in this project, verify rendered surfaces before saying the UI is fixed.

For screenshot-driven UI work, capture two Flutter-rendered PNGs every time:

- `regular`: normal viewport/first-screen size, used for what the user sees immediately.
- `full`: taller complete layout, used to catch wrapping, lower rows, scroll content, and clipped content.

Prefer Flutter-owned capture paths. For readable text on Windows desktop, use the real Flutter Windows embedder plus `RepaintBoundary.toImage()` from a tool entrypoint. Use OS/window screenshots only as a fallback after Flutter capture fails.

## Required Workflow

1. Inspect the affected screen, widgets, route, theme tokens, and providers before editing.
2. Compare against the design source when one exists, especially `design_handoff/design_handoff_fh_radio_studio/design/styles.css` and the matching screenshot.
3. Make the smallest layout change that addresses the visual or runtime problem.
4. Run:
   - `dart format <changed dart files>`
   - `flutter analyze`
5. Add or update a focused widget test when the issue can regress in layout, semantics, provider state, or runtime rendering.
6. Render the affected UI with realistic data and fixed viewports. For screenshot reports, produce both regular and full captures, and match the reference aspect/size when practical.
7. For desktop or route-level problems, run the Windows target or built app and inspect logs.
8. In the final answer, state exactly what was rendered or viewed, including both screenshot paths when captures were produced. Do not blur “tests passed” into “the UI was visually checked.”

## Project-Specific Commands

Run Flutter commands from `app/`.

Use the bundled script for the common verification path:

```powershell
.\.agents\skills\flutter-visual-qa\scripts\flutter_visual_qa.ps1 -Analyze -Test
.\.agents\skills\flutter-visual-qa\scripts\flutter_visual_qa.ps1 -BuildWindows -RunWindows -Route /backups
.\.agents\skills\flutter-visual-qa\scripts\flutter_visual_qa.ps1 -All -Route /backups -RunSeconds 45
.\.agents\skills\flutter-visual-qa\scripts\flutter_visual_qa.ps1 -Analyze -Test -CapturePlaylist
```

The script sets loopback proxy bypass, sets `TrackFileAccess=false`, stops stale `fh-radio-studio.exe` processes launched from this project's `app/build/windows` unless `-KeepExistingApp` is passed, runs the requested Flutter commands from `app/`, captures `flutter run` logs, and fails if runtime assertion patterns appear.

For playlist screenshot QA, `-CapturePlaylist` runs `app/tool/playlist_capture_main.dart` on the Windows target and exports two Flutter `RepaintBoundary.toImage()` PNGs:

- `app/build/visual_qa/playlist_regular.png` from a `1365x900` logical surface at `1.5` pixel ratio.
- `app/build/visual_qa/playlist_full.png` from a `1365x1800` logical surface at `1.5` pixel ratio.

Override sizes only when the reference screenshot calls for it:

```powershell
.\.agents\skills\flutter-visual-qa\scripts\flutter_visual_qa.ps1 `
  -CapturePlaylist `
  -RegularLogicalSize 1365x900 `
  -FullLogicalSize 1365x1800 `
  -CapturePixelRatio 1.5
```

Flutter test goldens are still useful for deterministic layout regression checks, but they may use test fonts. Do not use test-font golden text rendering as proof that real desktop fonts look correct.

Before tests or runs in agent shells, make loopback bypass proxies:

```powershell
$loopback = @('localhost','127.0.0.1','::1')
foreach ($name in @('NO_PROXY','no_proxy')) {
  $current = [Environment]::GetEnvironmentVariable($name, 'Process')
  $parts = @()
  if ($current) { $parts += $current.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
  foreach ($item in $loopback) { if ($parts -notcontains $item) { $parts += $item } }
  [Environment]::SetEnvironmentVariable($name, ($parts -join ','), 'Process')
}
```

For Windows build/run in agent shells:

```powershell
$env:TrackFileAccess = 'false'
flutter build windows
flutter run -d windows --route /backups
```

Scan run logs for:

- `Failed assertion`
- `Another exception was thrown`
- `RenderFlex overflowed`
- `semantics.parentDataDirty`
- route-specific provider/build exceptions

## Widget Test Pattern

For visual/runtime regressions, pump the exact screen with realistic providers:

- Set `tester.view.physicalSize` and `tester.view.devicePixelRatio`.
- Use `tester.ensureSemantics()` when the bug mentions semantics, `parentDataDirty`, `RenderObject`, accessibility, or Windows debug rendering assertions.
- Avoid `pumpAndSettle()` when the page can show indeterminate animations such as `CircularProgressIndicator`; pump fixed durations instead.
- Assert `tester.takeException()` is null after the rendered frame.

## Layout Guardrails

- Avoid `IntrinsicHeight` around complex interactive Flutter trees unless there is a measured need; it is expensive and can interact badly with semantics/debug rendering.
- Do not fix design screenshots by repeatedly nudging padding. Compare the actual source design’s grid, max width, font sizes, column widths, and component-specific CSS.
- Keep dense app surfaces compact by controlling text scale, column widths, max lines, overflow, and footer action wrapping.
- If a user provides a screenshot, do not finalize until a rendered screenshot/log check has been performed or you explicitly say why it was not possible.

## Minimum Evidence

For Flutter UI fixes in this repo, provide:

- `flutter analyze`
- Relevant `flutter test` or focused widget test
- Rendered proof: for screenshot-driven work, both regular and full Flutter captures; otherwise widget render with semantics or real Windows `flutter run`/desktop launch with clean logs
