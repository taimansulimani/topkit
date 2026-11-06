---
description: Topkit is live on the Mac App Store; how a change goes local, TestFlight, then a store release with notes.
---

# Topkit — release flow (live app)

Topkit 1.0 is live on the Mac App Store (`com.topkit.app`, Apple id 6761268614) since 27 Aug 2026, with paying users. Only Tommy is on TestFlight. The general rule is `apps-in-production` in agent-rules; this is the Topkit detail.

## Steps

1. **Local:** work on a branch (main is protected: PR plus both CI checks). Run the local build with `scripts/run-dev.sh`: it builds Debug and runs it as `/Applications/Topkit Dev.app`. Never hand him a build in `/tmp` or DerivedData: Settings only lists apps Launch Services can find by bundle id, which excludes those folders, so the permission prompt opens Settings with nothing to switch on. Debug and Release builds are **Topkit Dev** (`Topkit Dev.app`, `com.topkit.app.dev`, unsandboxed): their own entry in Privacy & Security, own settings and clipboard history, so testing never touches the store app's permissions. Only the `AppStore` config is `com.topkit.app`. Never give a local build the store id: macOS ties permissions to id plus signature, so the two builds keep revoking each other and "Quit & Reopen" launches the store copy. The file name matters as much as the id: Privacy & Security lists apps by file name, so a dev build named `Topkit.app` shows as a second "Topkit" and he flips the wrong switch. The "Check Bundle ID" build phase fails any build that breaks either.
2. **TestFlight:** `bundle exec fastlane fire message:"…"` on his word (see `topkit-fire-red-team`). It runs `upload_build` → `upload_to_testflight` only, never an App Store version. Report the build number and confirm it reached TestFlight via the API.
3. **Store release:** only on his explicit yes for that version. Before it: version bumped, `release_notes.txt` rewritten, metadata checked (below). `release` submits for review with `automatic_release: false`; releasing after approval is another yes.

## Version and build

- Version: `MARKETING_VERSION` in `Topkit.xcodeproj` (every target); `Topkit/Info.plist` reads it. 1.0 is live; 1.1 is next.
- Build: the "Stamp Build Number" phase writes `git rev-list --count HEAD` + 1000 into the built bundle. The offset exists because the repo was re-rooted on 1 Sep 2026 (count restarted) while App Store Connect already held builds up to 253. Never lower it. Read the number off the built `Info.plist`, not the source one.

## Release notes and listing

- What's New: `fastlane/metadata/en-GB/release_notes.txt` (UK spelling) and `en-US` (US spelling), rewritten for every version in user words. Never ship "Initial release" again.
- `release`, `upload_metadata` and `upload_store_listing` push every metadata file, screenshot and review note in the repo with `force`. Screenshots and previews are gitignored: check `fastlane/screenshots` and `fastlane/app-previews` exist on this Mac and match live before running them.
- `upload_app_previews` hardcodes version "1.0" and deletes the live previews before uploading: do not run it for 1.1 until that is fixed.
- `APP_STORE_REVIEW_NOTES.md` keeps the Guideline 2.4.5 auto-paste explanation on every submission.
