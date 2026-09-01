---
description: When the user says "fire", do a real pre-ship review before fastlane; automated checks are not enough.
---


# Topkit — "fire" release flow (red team first)

When the user says **fire** (or asks to ship / run the release lane), execute this flow immediately.
Do not ask for confirmation unless the user explicitly asked for a dry run / plan only.

## 1. Red-team review (you, in Cursor — required)

Treat this like a short security + quality review of **everything** that would be committed (when the tree is dirty). If the working tree is clean, there is no new diff to review; still run the lane for tests and upload.

- **Intent:** Does each change match the stated bug/feature? Any unrelated edits, debug prints, or commented-out code that should not ship?
- **Necessity:** Is new code actually used, or dead? Any duplicate paths (two ways to do the same thing)?
- **Security / privacy:** Secrets, API keys, tokens, PII logging, unsafe URLs, or weakening permissions (e.g. turning off sandbox for App Store builds)?
- **App Store metadata:** If `fastlane/metadata/` is in the diff, every public URL must be `https://topkitapp.com/` (see `.cursor/rules/topkit-app-store-metadata.mdc`). `upload_metadata` overwrites **all** listing fields from the repo.
- **Signing / entitlements:** App Store builds use `Topkit-AppStore` + `AppStore` (sandbox). Local test packages use `Release` without sandbox. Do not mix these up in `project.pbxproj` or Fastlane.
- **Tests:** If behavior changed, are tests updated or added where it matters?

If something is wrong, **fix or revert it** before running Fastlane.

## 2. Automated gate (Fastlane)

After the review above, run Fastlane:

`bundle exec fastlane fire message:"…"`

If the tree is clean, run:

`bundle exec fastlane fire`

Use a commit message whenever you have local changes to ship; if the tree is clean, `message` is ignored and commit/push is skipped.

The lane runs **automated** checks (diff stats, blocked paths, high-confidence secret patterns when there is a diff). That is a **safety net**, not a substitute for step 1.

## 3. What "fire" does (mechanical)

Tests → commit + push **only if** there are uncommitted changes → App Store Connect upload (sandboxed). Testing happens on TestFlight; the standalone `package_local` lane still exists if a local Release `.app` is ever needed.
