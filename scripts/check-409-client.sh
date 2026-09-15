#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ -n "${SPYCLASH_TEST_DESTINATION:-}" ]; then
  destination=$SPYCLASH_TEST_DESTINATION
else
  device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if ".iOS-" not in runtime:
        continue
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
else:
    sys.exit("No available iPhone Simulator runtime")
')
  destination="platform=iOS Simulator,id=$device"
fi
results=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-409-tests.XXXXXX")
xcodebuild test -project SpyClash.xcodeproj -scheme SpyClash \
  -destination "$destination" \
  -derivedDataPath "${SPYCLASH_TEST_DERIVED_DATA:-$results/DerivedData}" \
  -resultBundlePath "$results/Tests.xcresult" \
  -only-testing:SpyClashTests/Base44ClientRoomActionTests \
  CODE_SIGNING_ALLOWED=NO
printf 'Client test evidence: %s/Tests.xcresult\n' "$results"
