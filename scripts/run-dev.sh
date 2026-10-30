#!/usr/bin/env bash
# Build the Debug app and run it as /Applications/Topkit Dev.app.
#
# It has to live in /Applications: System Settings only lists an app under Privacy & Security
# when Launch Services can find it by bundle id, and it never finds apps in /tmp or
# DerivedData. Run from there, the permission prompt opens Settings with no Topkit Dev to
# switch on. Topkit Dev (com.topkit.app.dev) is a separate app from the App Store Topkit, so
# its permissions never touch the store copy's.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="/tmp/TopkitDD-dev"
BUILT="$DERIVED/Build/Products/Debug/Topkit Dev.app"
INSTALLED="/Applications/Topkit Dev.app"
BUNDLE_ID="com.topkit.app.dev"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

xcodebuild -project "$REPO_ROOT/Topkit.xcodeproj" -scheme Topkit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build -quiet

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "$INSTALLED/Contents/MacOS/" >/dev/null || break
  sleep 0.5
done

# Replace only Topkit Dev's own bundle; the App Store Topkit.app is never touched.
rm -rf "$INSTALLED"
ditto "$BUILT" "$INSTALLED"
codesign --verify "$INSTALLED"

# One registered copy per bundle id, or "Quit & Reopen" may relaunch a stale build.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED"

open -b "$BUNDLE_ID"
echo "Running $INSTALLED ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INSTALLED/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INSTALLED/Contents/Info.plist"))"
