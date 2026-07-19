#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
screens="$root/AppStoreAssets/Screenshots/en-US"
notes="$root/AppStoreAssets/APP_REVIEW_NOTES.md"
fields="$root/AppStoreAssets/APP_STORE_CONNECT_FIELDS.md"
testflight_acceptance="$root/AppStoreAssets/TESTFLIGHT_ACCEPTANCE.md"

expected_screens='01-online-playing.png
02-local-results.png
03-word-packs.png
04-home.png
05-community.png'

actual_count=$(find "$screens" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')
if [ "$actual_count" -ne 5 ]; then
  echo "Expected exactly five en-US App Store screenshots; found $actual_count." >&2
  exit 1
fi

for name in $expected_screens; do
  file="$screens/$name"
  if [ ! -f "$file" ]; then
    echo "Required App Store screenshot is missing: $name" >&2
    exit 1
  fi

  width=$(sips -g pixelWidth "$file" | awk '/pixelWidth:/ { print $2; exit }')
  height=$(sips -g pixelHeight "$file" | awk '/pixelHeight:/ { print $2; exit }')
  alpha=$(sips -g hasAlpha "$file" | awk '/hasAlpha:/ { print $2; exit }')
  if [ "$width" != 1284 ] || [ "$height" != 2778 ]; then
    echo "Unexpected dimensions for $name: ${width}x${height}." >&2
    exit 1
  fi
  if [ "$alpha" != no ]; then
    echo "App Store screenshot must be flattened without alpha: $name" >&2
    exit 1
  fi
done

if ! grep -Fq 'Prepared for iOS version 1.0, build 3.' "$notes"; then
  echo "App Review notes are not pinned to version 1.0 build 3." >&2
  exit 1
fi
if ! grep -Fq 'Select build `1.0 (3)` only.' "$fields"; then
  echo "App Store Connect field guide does not select build 1.0 (3)." >&2
  exit 1
fi
if ! grep -Fq 'version 1.0 build 3' "$testflight_acceptance" \
    || ! grep -Fq 'com.spyclash.app.limitless.weekly' "$testflight_acceptance" \
    || ! grep -Fq 'App Store Server Notifications V2' "$testflight_acceptance"; then
  echo "The physical-device acceptance gate is missing build, product, or notification coverage." >&2
  exit 1
fi
if ! grep -Fq 'visual reference only' "$root/AppStoreAssets/README.md" \
    || ! grep -Fq 'be attached to App Review' "$root/AppStoreAssets/README.md"; then
  echo "The local StoreKit screenshot is not explicitly blocked from review upload." >&2
  exit 1
fi

echo "App Store asset gate passed: five flattened 1284x2778 screenshots and build 3 metadata are present."
echo "The Sandbox/TestFlight subscription screenshot, secure review fields, and production tests remain separate submission gates."
