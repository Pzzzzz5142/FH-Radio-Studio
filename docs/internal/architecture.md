# Architecture Notes

## Product Goal

FH Radio Studio is a desktop workflow for replacing FH6 PC radio tracks with user audio while preserving race start, finish, freeroam, and loop behavior.

The app should make risky file writes explicit and auditable:

- project assets stay inside one project directory;
- packages are generated before deployment;
- game files are checked against a trusted baseline before deployment;
- game updates go through pending verification before promotion.

## Project Directory

```text
sources/                         imported local music
siren/                           Monster Siren import registry and audio
packages/current/                the only normal deployable package slot
packages/pending/                temporary package for pending game update verification
backups/baseline-current/        trusted original game baseline
backups/baseline-pending-verify/ pending game update baseline
analysis/                        waveform, AI, timing, loudness cache
.fh-radio-studio/project.json    project settings
.fh-radio-studio/playlist_plan.json
.fh-radio-studio/track_metadata.json
```

Project recovery and verification are based on baseline/package records.

## Package Contract

Package manifests use `radios`.

Top-level fields are summary/product metadata. Per-radio payload lives in `radios[*]`:

```json
{
  "schema_version": 2,
  "game": "FH6",
  "radio": 4,
  "station": "Horizon XS",
  "radios": [
    {
      "radio": 4,
      "radio_code": "XS",
      "music": [],
      "assignments": []
    }
  ],
  "package_files": []
}
```

## Baseline And Pending Flow

Normal path:

1. Create `baseline-current`.
2. Build `packages/current`.
3. Deploy package.
4. Update last-applied package fingerprint.

Game update path:

1. Detect current files differ from current baseline/package.
2. Save current game files as `baseline-pending-verify`.
3. Build `packages/pending` from pending files and current playlist plan.
4. After user verifies, promote pending baseline and package into current.

External conflict path:

- If protected files match no trusted record and the game build did not change, treat it as conflict.
- Let the user choose between current files and trusted baseline/package records.

## State Records

The project state model is centered on:

- trusted game baselines;
- generated package manifests;
- last-applied package fingerprints;
- pending verification records after a game update.
