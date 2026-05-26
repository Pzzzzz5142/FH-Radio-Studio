# FH Radio Studio Development Guide

This is the public developer guide for FH Radio Studio. It explains how the project is organized, how to run it locally, and which commands are expected to stay stable for contributors.

## Repository Layout

```text
app/                         Flutter desktop app
backend/fh_radio_studio_cli/ Python CLI and product logic
tools/                       release/build/test utilities
test/                        Python CLI tests and fixtures
docs/development.md          public developer guide
```

The desktop app is the main product surface. The Python CLI is the execution engine behind scanning game files, analyzing audio, building packages, managing baselines, and deploying files.

## Runtime Model

All Python product execution goes through `uv`.

Use:

```powershell
uv run fh-radio-studio ...
uv run python -m backend.fh_radio_studio_cli ...
```

Avoid adding a second Python package manager path. Dependencies belong in `pyproject.toml` and `uv.lock`.

The default managed Python version is `3.12`. The app passes Python/uv invocation through `UvRuntime` in `app/lib/core/fh_radio_studio_cli.dart`; Flutter UI/state code should not build its own `uv run` command line.

## Local Setup

From the repository root:

```powershell
uv sync
```

From the Flutter app directory:

```powershell
cd app
flutter pub get
```

Run the desktop app:

```powershell
cd app
flutter run -d windows
```

If a Windows build appears to hang inside MSBuild/C++ from an agent-managed shell, set:

```powershell
$env:TrackFileAccess = "false"
```

If Flutter tests fail while loading from `127.0.0.1`, make sure local loopback bypasses any proxy:

```powershell
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = "localhost,127.0.0.1,::1"
```

## Core Workflows

Check the CLI and game directory:

```powershell
uv run fh-radio-studio probe --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6"
uv run fh-radio-studio status --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6" --radio 4 --source CHS --target EN --json
```

Create a trusted baseline before deploying packages:

```powershell
uv run fh-radio-studio baseline create `
  --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6" `
  --out-dir ".\work\backups\baseline-current" `
  --state current `
  --yes
```

Analyze audio:

```powershell
uv run fh-radio-studio analyze-audio ".\music\01 - Example.flac" --profile local-heavy --json
```

Build and deploy a package:

```powershell
uv run fh-radio-studio build-package ".\music" `
  --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6" `
  --radio 4 `
  --baseline-manifest ".\work\backups\baseline-current\baseline_manifest.json" `
  --playlist-mode only `
  --out-dir ".\work\packages\current"

uv run fh-radio-studio deploy-package ".\work\packages\current\package" `
  --game-dir "C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6" `
  --baseline-manifest ".\work\backups\baseline-current\baseline_manifest.json" `
  --last-applied-manifest ".\work\.fh-radio-studio\last_applied_package_manifest.json" `
  --yes
```

## Data Contracts

Package manifests use the `radios` shape. Summary and product metadata stays at the top level; per-radio payload lives under `radios`.

Playlist drafts live at:

```text
.fh-radio-studio/playlist_plan.json
```

Language changes are packaged through `build-package --source ... --target ...` and written by `deploy-package`.

## AI Profiles

Available analysis profiles:

- `local-base`: lightweight fallback; default for `analyze-audio`.
- `local-deep`: Beat This, SongFormer, and MERT.
- `local-heavy`: local-deep plus Demucs; product-quality target.

AI dependencies are Dependency Groups in `pyproject.toml`. Torch is selected through the `torch-cpu` / `torch-cu128` extras.

## Testing

Install local commit hooks:

```powershell
uv run --locked pre-commit install
```

Run all pre-commit hooks manually:

```powershell
uv run --locked pre-commit run --all-files
```

Python checks:

```powershell
uv run python -m compileall backend tools test
uv run pytest test/test_cli_mock_game.py test/test_ai_timepoints.py
```

Flutter checks:

```powershell
cd app
flutter analyze
flutter test
```

For focused Flutter verification after state/CLI integration changes:

```powershell
flutter test test/project_workspace_test.dart test/playlist_catalog_state_test.dart test/studio_state_test.dart test/fh_radio_studio_cli_runtime_test.dart test/widget_test.dart
```

## Commit Messages

Use bracketed conventional commit messages:

```text
[type][scope] summary
```

Scope is optional for repository-wide maintenance changes:

```text
[chore] update project metadata
```

Rules:

- Use lowercase `type` and `scope`.
- Keep `summary` in English, imperative, lowercase after the brackets, and without a trailing period.
- Keep the header concise, preferably at or below 72 characters.
- Prefer one type per commit.
- If a change genuinely cannot be split and is both a bug fix and a performance optimization, use the compound type `[fix/perf][scope] summary`; do not write `[fix][perf]`, because the second bracket is reserved for scope.
- Mark breaking changes with `!` on the type, for example `[feat!][runtime] remove global uv fallback`, and include a `BREAKING CHANGE:` footer.
- For `fix` and `fix/perf` commits, keep the header summary focused on the user-visible bug, failure, or regression that was fixed; put the underlying cause, implementation details, and performance impact in the body.
- For `fix` and `fix/perf` commits, always include a body with `Root cause:` and `Fix:` paragraphs. `Root cause:` should explain why the bug happened, and `Fix:` should explain the concrete change that prevents it. For `fix/perf`, also mention the performance improvement in `Fix:` or a short additional paragraph.
- For non-`fix` commits, use a body only when it adds why, impact, migration notes, or test coverage.

Types:

```text
feat, fix, perf, refactor, build, ci, test, docs, style, chore, revert
```

The only supported compound type is:

```text
fix/perf
```

Preferred scopes:

```text
app, backend, audio, analysis, runtime, release, windows, tools, deps, docs, ci
```

Examples:

```text
[fix][runtime] launch release uv from bundled toolchain
[fix/perf][analysis] avoid repeated local-heavy scoring
[feat][audio] preserve siren playlist assignments in package builds
[build][windows] require bundled release runtime artifacts
[docs][release] document portable runtime preparation
[test][analysis] cover local-heavy point selection rules
[refactor][app] centralize cli process creation in UvRuntime
[chore] update project metadata
```

Fix commit body example:

```text
[fix][runtime] launch release uv from bundled toolchain

Root cause: Release startup still resolved uv from PATH before checking the portable app tools directory, so machines without a global uv install failed to launch the backend.

Fix: Resolve uv through UvRuntime's bundled release path first and preserve the offline release flags when spawning backend commands.
```

## Release Build

Build a Windows release package from the repository root:

```powershell
.\tools\build_release.ps1 -CleanBuild
```

The release path prepares an offline uv runtime, wheelhouse, Python toolchain, and bundled audio tools, then builds the Flutter Windows app and writes an archive under `dist/`.

The public product release id is `app/pubspec.yaml` `version`. On `main`, it may carry the current RC id such as `0.1.0-rc.1`, but `main` is still a development branch and should show build commit details. Build commit details are hidden only for real release branches named `release/v<major>.<minor>.<patch>` such as `release/v0.1.0`, or RC-specific branches named `release/v<major>.<minor>.<patch>-rc.<n>` such as `release/v0.1.0-rc.1`. All other branches, including `dev/*` and `feature/*`, show build commit details. When bumping the version, also update `app/lib/core/app_info.dart` and run `flutter pub get`.

GitHub Actions release packaging is validation-first. Push a release branch that matches the app version, for example `release/v0.1.0-rc.1`, and `.github/workflows/release.yml` will run the Python and Flutter test suites, build the Windows release archive, generate a SHA256 file, and upload both files as a workflow artifact. The workflow does not create, update, or publish a GitHub Release. Download the `FHRadioStudio-v<version>-windows-x64` workflow artifact and test it before publishing.

After validation, create or publish the GitHub Release from the Releases page using the matching tag, for example `v0.1.0-rc.1`, mark RCs as prereleases, and upload the tested archive plus its `.sha256` file. If the app version contains build metadata such as `0.1.0-rc.1+7`, the workflow accepts either `v0.1.0-rc.1` or `v0.1.0-rc.1+7`. Normal RC builds show the release id only; build commit details are reserved for non-RC dev builds.

The CI workflows regenerate ignored test fixtures before Flutter tests. Keep `test/fixtures/` and `test/project/` out of Git; they are build/test outputs.

## Contribution Notes

- Keep product logic in the Python CLI when it touches FH6 files, manifests, package generation, baselines, or audio processing.
- Keep actual uv invocation construction centralized in `UvRuntime`.
- Prefer structured JSON contracts over parsing CLI human output.
- Keep package and baseline behavior aligned with the documented data contracts.
- Do not commit generated workspaces, build outputs, local media, or internal notes.
