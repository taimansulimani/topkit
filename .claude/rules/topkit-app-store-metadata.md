---
description: App Store metadata URLs and upload safety — canonical topkitapp.com only.
---


# Topkit — App Store metadata

## Canonical public URLs

Every locale (`en-US`, `en-GB`, etc.) in `fastlane/metadata/**` uses exactly:

- `marketing_url.txt`: `https://topkitapp.com/`
- `support_url.txt`: `https://topkitapp.com/`
- `privacy_url.txt`: `https://topkitapp.com/privacy/` (App Review wants the policy on its own page)

`scripts/validate-app-store-metadata.sh` enforces these values.

Never use `tommasorota.com`, `/work/topkit.html`, or any other domain/path in metadata.

## Before uploading metadata

1. Run `scripts/validate-app-store-metadata.sh` (also runs in test gates and before Fastlane metadata upload).
2. `upload_metadata` / `upload_store_listing` / `release` push **all** files under `fastlane/metadata/` — not just the file you edited. Stale repo values overwrite App Store Connect.
3. If only one field changed (e.g. description spelling), still verify the URL files in the repo match the values above before running deliver.

## Contact email vs app URLs

`APP_REVIEW_CONTACT_EMAIL` in `.env.default` is the App Review contact address, not a public listing URL. Do not conflate it with marketing/support/privacy URLs.
