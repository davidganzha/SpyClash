#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
if [ -n "${SPYCLASH_TEST_DESTINATION:-}" ]; then
  destination=$SPYCLASH_TEST_DESTINATION
else
  device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    phones = [d for d in devices[runtime] if ".iOS-" in runtime and d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
else:
    sys.exit("No available iPhone Simulator runtime")
')
  destination="platform=iOS Simulator,id=$device"
fi
results=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-public-config.XXXXXX")
sh scripts/tests/check-ios-release-bundle_test.sh
xcodebuild test -project SpyClash.xcodeproj -scheme SpyClash-Supabase-Public \
  -configuration SupabasePublicRelease -destination "$destination" \
  -derivedDataPath "${SPYCLASH_TEST_DERIVED_DATA:-$results/DerivedData}" \
  -resultBundlePath "$results/PublicConfigurationTests.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:SpyClashPublicReleaseTests/SupabasePublicReleaseTests \
  ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Automatic PROVISIONING_PROFILE_SPECIFIER=
xcrun xcresulttool get test-results summary \
  --path "$results/PublicConfigurationTests.xcresult" --format json | python3 -c '
import json, sys
summary = json.load(sys.stdin)
if (summary.get("passedTests"), summary.get("failedTests"), summary.get("skippedTests")) != (3, 0, 0):
    sys.exit("Public configuration gate requires all three runtime tests to execute and pass")
print("Public configuration: 3 passed, 0 failed, 0 skipped")
'
printf 'Public configuration evidence: %s/PublicConfigurationTests.xcresult\n' "$results"
