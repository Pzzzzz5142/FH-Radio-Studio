# Release Packaging Notes

## Build Entry

Windows release builds run from the repository root:

```powershell
.\tools\build_release.ps1 -CleanBuild
```

The build prepares runtime inputs, builds the Flutter Windows app, and writes the release archive under `dist/`.

## Runtime Inputs

Release packages include:

- bundled uv executable;
- prepared Python toolchain;
- offline wheel/runtime inputs;
- seeded uv cache for rebuilding the local virtual environment;
- core audio tools under the packaged toolchain.

Release packages do not include prebuilt `toolchain/envs/*` virtual
environments. `tools/prepare_release_runtime.py` syncs once into a temporary
`.seed-env` to validate the lockfile and seed the bundled cache, then removes
that environment. The installed app creates `toolchain/envs/base` locally on
first run, and creates AI profile environments only when the user syncs those
profiles.

The preparation path uses:

```powershell
uv run python tools/prepare_release_runtime.py
```

Generated inputs live under `.fh-radio-studio-dev/release-inputs/`.

## Version Source

The public product release id comes from `app/pubspec.yaml` `version`.

Build commit details are hidden only for real release branches. A real release
branch must be named `release/v<major>.<minor>.<patch>`, for example
`release/v0.1.0`; an RC-specific branch may use
`release/v<major>.<minor>.<patch>-rc.<n>`, for example
`release/v0.1.0-rc.1`.

All other branches, including `main`, `dev/*`, and `feature/*`, are treated as
development builds and should surface build commit details.

When changing it, keep `app/lib/core/app_info.dart` in sync and refresh Flutter generated package metadata:

```powershell
cd app
flutter pub get
```

## Verification

Release validation should include:

```powershell
uv run python -m compileall backend tools test
uv run pytest test/test_cli_mock_game.py test/test_ai_timepoints.py

cd app
flutter analyze
flutter test
```
