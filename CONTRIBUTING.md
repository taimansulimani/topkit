# Contributing

Issues and pull requests welcome.

`main` is protected: open a PR from a branch. CI must pass before merge.

## Build from source

See [Install → Build from source](README.md#build-from-source) in the README.

## Tests

```sh
swift test
xcodebuild \
  -project Topkit.xcodeproj \
  -scheme Topkit \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build-for-testing
```

## Branding

Do not use the Topkit name or logo to distribute a fork as the official app. See [Trademark](README.md#trademark).
