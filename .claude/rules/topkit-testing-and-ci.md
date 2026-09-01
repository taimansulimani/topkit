---
description: Topkit tests and CI are merge gates; run and fix before merging.
---


# Topkit — tests and CI (non-negotiable)

- **Do not merge** changes that break tests. Fix failures or revert; do not disable tests to go green.
- **Local checks** (run from repo root before pushing):
  - `swift test` — SwiftPM / `TopkitCore` + `Tests/TopkitTests`
  - `xcodebuild -project Topkit.xcodeproj -scheme Topkit -destination 'platform=macOS' test` — app module + hosted unit tests (matches CI’s Xcode job)
- **CI:** `.github/workflows/ci.yml` runs both jobs on push/PR to `main`/`master`. **Both jobs must pass.**
- **When changing logic** covered by helpers (clipboard, hex, shortcuts, screenshot paths, image helpers, etc.), **add or update tests** in `Tests/TopkitTests/` in the same change when practical.
- **`TopkitUITests`** may be skipped in the shared Xcode scheme; default CI does **not** rely on UI tests. Unit tests are the primary automated gate.
- **New Swift files** under `Topkit/` must be added to **both** `Package.swift` / `TopkitCore` layout (if applicable) **and** `Topkit.xcodeproj` so Xcode builds and tests do not drift.
