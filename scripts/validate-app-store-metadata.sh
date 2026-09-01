#!/usr/bin/env bash
# Fail if App Store metadata URLs drift from the canonical site or use blocked domains.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_ROOT="$REPO_ROOT/fastlane/metadata"
SITE_URL="https://topkitapp.com/"
BLOCKED_DOMAINS=("tommasorota.com")

# Each public URL file and the exact value it must hold. Marketing and support
# point at the site root; the privacy policy has its own page, because App Review
# expects that link to land on a policy rather than the homepage.
URL_FILES=(
  "marketing_url.txt=$SITE_URL"
  "support_url.txt=$SITE_URL"
  "privacy_url.txt=${SITE_URL}privacy/"
)

errors=0

fail() {
  echo "❌ $1"
  errors=$((errors + 1))
}

if [ ! -d "$METADATA_ROOT" ]; then
  echo "❌ Missing metadata directory: fastlane/metadata"
  exit 1
fi

for locale_dir in "$METADATA_ROOT"/*/; do
  [ -d "$locale_dir" ] || continue
  locale="$(basename "$locale_dir")"

  for entry in "${URL_FILES[@]}"; do
    file="${entry%%=*}"
    expected="${entry#*=}"
    path="$locale_dir$file"
    if [ ! -f "$path" ]; then
      fail "Missing fastlane/metadata/$locale/$file"
      continue
    fi

    content="$(tr -d '[:space:]' < "$path")"
    if [ "$content" != "$expected" ]; then
      fail "fastlane/metadata/$locale/$file must be exactly $expected (got: $(tr -d '\n' < "$path"))"
    fi

    for blocked in "${BLOCKED_DOMAINS[@]}"; do
      if grep -qi "$blocked" "$path"; then
        fail "fastlane/metadata/$locale/$file contains blocked domain: $blocked"
      fi
    done
  done
done

while IFS= read -r -d '' file; do
  for blocked in "${BLOCKED_DOMAINS[@]}"; do
    if grep -qi "$blocked" "$file"; then
      fail "${file#"$REPO_ROOT"/} contains blocked domain: $blocked"
    fi
  done
done < <(find "$METADATA_ROOT" -type f -print0)

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "App Store metadata validation failed ($errors issue(s))."
  exit 1
fi

echo "✅ App Store metadata validated (public URLs point at $SITE_URL)."
