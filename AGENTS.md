# Repository Instructions

## File Encoding

- All project files are expected to be read and written as UTF-8.
- When editing files, preserve UTF-8 encoding and avoid falling back to system-default encodings such as ANSI, GBK, or Windows-1252.
- In PowerShell, prefer commands that explicitly specify UTF-8 when reading or writing text, for example `Get-Content -Encoding UTF8` and `Set-Content -Encoding UTF8`.
- In Python scripts, pass `encoding="utf-8"` when opening text files.
- Do not change line endings or file encoding unless the task explicitly requires it.

## Commit Messages

- Commit message rules are maintained in `docs/development.md` under "Commit Messages"; consult that section when creating commits. Do not duplicate the commit spec in this file.

## Python Runtime and uv

- All Python CLI execution must go through `uv`. Dev app code should call the `fh-radio-studio` console script through the centralized Dart `UvRuntime`; agent shell commands can use `uv run fh-radio-studio ...` or `uv run python -m backend.fh_radio_studio_cli ...` when directly debugging the module. Do not call bare `python -m backend.fh_radio_studio_cli` from app code, tests, docs, or agent commands unless explicitly debugging a non-uv failure mode.
- Python dependencies are declared in `pyproject.toml` and synchronized with `uv sync` / `uv run`; do not introduce ad hoc `pip install`, `uv pip install`, or a second package manager path in app code, tests, docs, or manifests.
- For PyTorch dependencies in project mode, use the `torch-cu128` / `torch-cpu` optional extras declared in `pyproject.toml`; the Dart uv runtime selects the CUDA extra on NVIDIA Windows/Linux machines and the CPU extra otherwise.
- Keep dev and release uv paths separate. Dev uses the repo-local toolchain home, normally `<repo>/.fh-radio-studio-dev/toolchain` with environments under `envs/` and cache under `uv/cache`. Release uses the portable app folder's `toolchain/` directory unless explicitly overridden.
- Flutter/Dart code must centralize actual uv process invocation construction through `UvRuntime` helpers in `app/lib/core/fh_radio_studio_cli.dart`; do not hand-roll separate executable `uv run` / `uv sync` paths in UI or state code.
- Dev defaults to an editable CLI install. Keep dev pointed at the repo root project so `uv run fh-radio-studio ...` sees Python source changes without rebuilding a wheel.
- Release defaults to wheel/offline/bundled-cache execution. Release `UvRuntime` uses `<app>/runtime`, `<app>/runtime/wheels`, `<app>/toolchain/python`, `<app>/toolchain/uv/cache`, `--no-editable`, `--offline`, and `--no-python-downloads`; do not relax these guards unless explicitly debugging with `FH_RADIO_STUDIO_ALLOW_RELEASE_OVERRIDES=1`.
- Release builds should bundle uv, prepared Python runtime inputs, and core audio tools instead of requiring users to install uv or ffmpeg/vgmstream/fsbankcl globally. Prepare inputs with `uv run python tools/prepare_release_runtime.py`; Windows CMake can copy `.fh-radio-studio-dev/release-inputs/runtime` into `<app>/runtime`, `.fh-radio-studio-dev/release-inputs/toolchain` into `<app>/toolchain`, and `.fh-radio-studio-dev/release-inputs/uv/windows/uv.exe` into `<app>/tools/uv/uv.exe`. The prepared toolchain must include `tools/audio/ffmpeg/ffmpeg.exe`, `tools/audio/vgmstream/vgmstream-cli.exe`, and `tools/audio/fmod/fsbankcl.exe`; `fh-radio-studio install-tools --force` remains the repair fallback if a user's local bundled tools are deleted or damaged. Release/CI packaging should set `FH_RADIO_STUDIO_REQUIRE_BUNDLED_UV=ON`, `FH_RADIO_STUDIO_REQUIRE_RELEASE_RUNTIME=ON`, `FH_RADIO_STUDIO_REQUIRE_RELEASE_TOOLCHAIN=ON`, and `FH_RADIO_STUDIO_REQUIRE_RELEASE_AUDIO_TOOLS=ON` so missing artifacts fail the build. Do not revive `third_party/` just for uv release inputs.

## Frontend/Backend Separation

- The Python CLI is the single source of truth for track metadata and FH6 file
  parsing. Anything that reads `RadioInfo_*.xml`, resolves track title/artist,
  maps tracks back to project sources, or rebuilds a playlist plan belongs in the
  CLI and is surfaced through a structured command output (JSON or a written
  file). Do not reimplement that logic in the Flutter app.
- The UI calls the CLI and consumes its result; it must not maintain a second
  metadata mechanism (XML parsing, filename guessing, `title|artist` matching) in
  Dart. Example: reconstructing a playlist from the live game vs. baseline diff is
  the `reconstruct-plan` subcommand, whose output the UI reads through
  `PlaylistPlanStore`. See `docs/design-decisions.md`.
- Dart helpers like `isUiSupportedRadio` / `_radioAssignmentLabel` are for
  presentation only; keep their authoritative counterparts
  (`is_ui_supported_radio`, `radio_code_for_station`) in the CLI.

## AI Timepoint Debugging

- When debugging or validating point-selection rules, focus on `analyze-audio --profile local-heavy` results only. `local-base` may be used for narrow baseline unit isolation, but it should not be treated as the product-quality selection result.

## Flutter Windows Build in Agent Shells

- When running `flutter build windows` or `flutter run -d windows` from Codex/agent-managed shells, set `$env:TrackFileAccess = "false"` first if MSBuild appears to hang.
- The observed failure mode is `cl.exe` processes stuck with threads in `Wait / Suspended` state and zero CPU usage during the CMake/MSBuild phase.
- This is a Visual C++/MSBuild file tracking issue in the agent shell environment, not a Flutter project requirement. A normal interactive PowerShell may build successfully without this variable.

## Localhost Proxy Bypass in Agent Shells

- When agent-managed shells use HTTP(S) proxy environment variables, make sure local loopback traffic bypasses the proxy.
- Prefer setting both uppercase and lowercase variants, for example:
  - `$env:NO_PROXY = "localhost,127.0.0.1,::1"`
  - `$env:no_proxy = "localhost,127.0.0.1,::1"`
- If an existing `NO_PROXY` or `no_proxy` value is present, append `localhost`, `127.0.0.1`, and `::1` instead of replacing unrelated entries.
- This is likely an agent environment workaround for local dev servers and loopback API calls, not a project runtime requirement.
