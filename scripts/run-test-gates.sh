#!/usr/bin/env bash
# Run local test gates required before push/merge.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "🧪 Running Topkit test gates..."
echo "0) validate App Store metadata URLs"
"$REPO_ROOT/scripts/validate-app-store-metadata.sh"

echo ""
echo "1) swift test"
swift test

echo ""
echo "2) xcodebuild build-for-testing (macOS destination)"
# NOTE: intentionally build-for-testing, NOT test. Topkit is a menu-bar agent whose
# unit-test target is hosted IN the app, so `xcodebuild … test` launches the app as the
# test runner. That launch hangs unreliably ("test runner hung before establishing
# connection" / linkd.autoShortcut 4097), especially on a second back-to-back run (fire's
# ci + this pre-push hook). The hosted unit tests are a strict subset of `swift test`
# above (same pure-logic files), so running them again adds no coverage — only the hang.
# build-for-testing still compiles the app target AND the test bundle (catching any
# Xcode-target compile breakage) without launching anything.
xcodebuild \
  -project Topkit.xcodeproj \
  -scheme Topkit \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build-for-testing

echo ""
echo "✅ All local test gates passed."

