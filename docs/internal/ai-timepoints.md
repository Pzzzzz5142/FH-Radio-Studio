# AI Timepoint Notes

## Product Contract

AI analysis proposes candidates. It does not replace user confirmation.

The editor consumes:

- waveform bins;
- provider statuses;
- beat/grid evidence;
- segment labels;
- ranked candidates for TrackDrop, PostDrop, TrackLoop, and PostLoop;
- marker seconds for confirmed output.

## Profiles

- `local-base`: lightweight fallback, default `analyze-audio` path.
- `local-deep`: local-base plus Beat This, SongFormer, and MERT.
- `local-heavy`: local-deep plus Demucs; product-quality target.

## Providers

- baseline MIR: always available fallback.
- Beat This: beat/downbeat grid and BPM.
- SongFormer: structure labels and section boundaries.
- MERT: candidate scoring and loop similarity evidence.
- Demucs: stem-aware evidence for heavy profile.

Provider failures should degrade the payload, not break the editor contract.

## Dependency Model

Python dependencies are declared in `pyproject.toml`.

AI Dependency Groups:

- `ai-beat-this`
- `ai-songformer`
- `ai-mert`
- `ai-demucs`

Torch is selected with `torch-cpu` or `torch-cu128` extras. The Flutter app uses `UvRuntime` to choose the extra.

## Validation Focus

When validating product-quality point selection, use:

```powershell
uv run fh-radio-studio analyze-audio <track> --profile local-heavy --json
```

`local-base` is only a fallback/baseline isolation path.
