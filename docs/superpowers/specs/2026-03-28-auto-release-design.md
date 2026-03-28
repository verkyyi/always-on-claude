# Auto-Release Workflow Design

## Summary

A scheduled GitHub Actions workflow that automatically creates version tags when enough commits accumulate on `main`, triggering the existing release pipeline.

## Trigger

- **Schedule:** Daily at midnight UTC (`0 0 * * *`)
- **Manual:** `workflow_dispatch` for on-demand runs

## Logic

1. Find the most recent `v*` tag, or fall back to the initial commit if none exist
2. Count non-merge commits on `main` since that tag
3. If count < 10, exit early with a summary log
4. Generate tag: `vYYYY.MM.DD` (UTC date)
5. If that tag already exists, skip (no same-day duplicate releases)
6. Create and push the tag
7. The existing `release.yml` triggers on the `v*` tag push and handles:
   - GitHub Release creation with auto-generated changelog
   - Docker image version tagging on GHCR

## Versioning

- **Format:** Calendar-based, `vYYYY.MM.DD`
- **Collision handling:** Skip if tag exists for today

## Threshold

- **10 non-merge commits** since last tag

## Permissions

- `contents: write` — required to push tags

## Files

- **New:** `.github/workflows/auto-release.yml`
- **Unchanged:** `.github/workflows/release.yml`
