fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac ci

```sh
[bundle exec] fastlane mac ci
```

Run local CI-equivalent test gates

### mac fire

```sh
[bundle exec] fastlane mac fire
```

One-shot: red-team diff, tests, commit+push (if dirty), App Store Connect upload

### mac package_local

```sh
[bundle exec] fastlane mac package_local
```

Build a local Release .app (no App Sandbox) for sharing/testing

### mac upload_build

```sh
[bundle exec] fastlane mac upload_build
```

Archive and upload a build to TestFlight (no submission)

### mac upload_app_previews

```sh
[bundle exec] fastlane mac upload_app_previews
```

Upload App Preview videos to App Store Connect (max 3 per locale)

### mac upload_listing_copy

```sh
[bundle exec] fastlane mac upload_listing_copy
```

Upload listing copy + review notes only (no binary, no screenshots/previews)

### mac upload_metadata

```sh
[bundle exec] fastlane mac upload_metadata
```

Upload metadata/screenshots/review notes only (no binary upload)

### mac upload_store_listing

```sh
[bundle exec] fastlane mac upload_store_listing
```

Upload metadata, screenshots, and app previews (no binary upload)

### mac release

```sh
[bundle exec] fastlane mac release
```

Upload build + metadata and submit the latest build for review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
