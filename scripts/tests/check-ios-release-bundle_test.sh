#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
gate="$root/scripts/check-ios-release-bundle.sh"
mock_bin="$root/scripts/tests/fixtures"
test_root=$(mktemp -d /tmp/spyclash-release-gate-tests.XXXXXX)

cleanup() {
  case "$test_root" in
    /tmp/spyclash-release-gate-tests.*) rm -rf -- "$test_root" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

plist_add() {
  plist=$1
  command=$2
  /usr/libexec/PlistBuddy -c "$command" "$plist" >/dev/null
}

make_entitlements() {
  output=$1
  identifier=$2
  team=$3
  include_push=$4
  include_sign_in=$5

  plutil -create xml1 "$output"
  plist_add "$output" "Add :application-identifier string $team.$identifier"
  plist_add "$output" "Add :com.apple.developer.team-identifier string $team"
  if [ "$include_push" = true ]; then
    plist_add "$output" 'Add :aps-environment string production'
  fi
  if [ "$include_sign_in" = true ]; then
    plist_add "$output" 'Add :com.apple.developer.applesignin array'
    plist_add "$output" 'Add :com.apple.developer.applesignin:0 string Default'
  fi
}

make_fixture() {
  destination=$1
  platform=$2
  signed=$3
  team=${4:-3Z64QKNL54}
  app="$destination/SpyClash.app"
  widget="$app/PlugIns/SpyClashWidgets.appex"

  mkdir -p "$widget"
  plutil -create xml1 "$app/Info.plist"
  plist_add "$app/Info.plist" 'Add :CFBundleIdentifier string com.spyclash.ios'
  plist_add "$app/Info.plist" 'Add :CFBundleShortVersionString string 1.0'
  plist_add "$app/Info.plist" 'Add :CFBundleVersion string 99'
  plist_add "$app/Info.plist" 'Add :CFBundleExecutable string SpyClash'
  plist_add "$app/Info.plist" "Add :DTPlatformName string $platform"
  plist_add "$app/Info.plist" 'Add :NSSupportsLiveActivities bool true'
  touch "$app/SpyClash"
  chmod +x "$app/SpyClash"
  cp "$root/SpyClash/Resources/PrivacyInfo.xcprivacy" "$app/PrivacyInfo.xcprivacy"

  plutil -create xml1 "$widget/Info.plist"
  plist_add "$widget/Info.plist" 'Add :CFBundleIdentifier string com.spyclash.ios.widgets'
  plist_add "$widget/Info.plist" 'Add :CFBundleExecutable string SpyClashWidgets'
  plist_add "$widget/Info.plist" 'Add :NSExtension dict'
  plist_add "$widget/Info.plist" 'Add :NSExtension:NSExtensionPointIdentifier string com.apple.widgetkit-extension'
  touch "$widget/SpyClashWidgets"
  chmod +x "$widget/SpyClashWidgets"

  if [ "$signed" = true ]; then
    touch "$app/embedded.mobileprovision" "$widget/embedded.mobileprovision"
    make_entitlements \
      "$app/.mock-entitlements.plist" com.spyclash.ios "$team" true true
    make_entitlements \
      "$widget/.mock-entitlements.plist" com.spyclash.ios.widgets "$team" false false
  fi

  printf '%s\n' "$app"
}

pass_count=0
fail_count=0

expect_pass() {
  name=$1
  shift
  if output=$(PATH="$mock_bin:$PATH" "$@" 2>&1); then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s\n%s\n' "$name" "$output" >&2
    fail_count=$((fail_count + 1))
  fi
}

expect_fail_with() {
  name=$1
  expected=$2
  shift 2
  if output=$(PATH="$mock_bin:$PATH" "$@" 2>&1); then
    printf 'FAIL: %s unexpectedly passed\n' "$name" >&2
    fail_count=$((fail_count + 1))
  elif printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s returned the wrong diagnostic\n%s\n' "$name" "$output" >&2
    fail_count=$((fail_count + 1))
  fi
}

simulator_app=$(make_fixture "$test_root/simulator" iphonesimulator false)
expect_pass "auto accepts an unsigned Simulator bundle" "$gate" "$simulator_app"
expect_pass "explicit Simulator mode stays backward compatible" \
  "$gate" --simulator "$simulator_app"
expect_fail_with "signed mode rejects an unsigned Simulator bundle" \
  'SpyClash app is missing embedded.mobileprovision.' \
  "$gate" --signed "$simulator_app"

signed_app=$(make_fixture "$test_root/signed" iphoneos true)
expect_pass "auto validates effective entitlements for iphoneos" "$gate" "$signed_app"

development_push_app=$(make_fixture "$test_root/development-push" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :aps-environment development' \
  "$development_push_app/.mock-entitlements.plist" >/dev/null
expect_pass "signed device accepts development APNs entitlement" \
  "$gate" "$development_push_app"

adhoc_app=$(make_fixture "$test_root/adhoc" iphoneos true)
touch "$adhoc_app/.mock-adhoc-signature"
expect_fail_with "signed iphoneos rejects an ad-hoc signature" \
  'is ad-hoc signed instead of certificate-signed.' \
  "$gate" "$adhoc_app"

archive_root="$test_root/SpyClash.xcarchive"
mkdir -p "$archive_root/Products/Applications"
make_fixture "$archive_root/Products/Applications" iphoneos true >/dev/null
expect_pass "signed mode resolves an xcarchive" "$gate" --signed "$archive_root"

missing_push_app=$(make_fixture "$test_root/missing-push" iphoneos true)
/usr/libexec/PlistBuddy -c 'Delete :aps-environment' \
  "$missing_push_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed iphoneos rejects missing APNs entitlement" \
  'effective entitlements are missing a valid aps-environment.' \
  "$gate" "$missing_push_app"

missing_sign_in_app=$(make_fixture "$test_root/missing-sign-in" iphoneos true)
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' \
  "$missing_sign_in_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed iphoneos rejects missing Sign in with Apple" \
  'effective entitlements are missing Sign in with Apple Default.' \
  "$gate" "$missing_sign_in_app"

invalid_widget_app=$(make_fixture "$test_root/invalid-widget" iphoneos true)
touch "$invalid_widget_app/PlugIns/SpyClashWidgets.appex/.mock-invalid-signature"
expect_fail_with "signed iphoneos rejects an invalid widget signature" \
  'Live Activity extension has an invalid or incomplete code signature.' \
  "$gate" "$invalid_widget_app"

missing_widget_profile_app=$(make_fixture "$test_root/missing-widget-profile" iphoneos true)
unlink "$missing_widget_profile_app/PlugIns/SpyClashWidgets.appex/embedded.mobileprovision"
expect_fail_with "signed iphoneos rejects a widget without an embedded profile" \
  'Live Activity extension is missing embedded.mobileprovision.' \
  "$gate" "$missing_widget_profile_app"

wrong_team_app=$(make_fixture "$test_root/wrong-team" iphoneos true)
make_entitlements \
  "$wrong_team_app/PlugIns/SpyClashWidgets.appex/.mock-entitlements.plist" \
  com.spyclash.ios.widgets DIFFERENTTEAM false false
expect_fail_with "signed iphoneos rejects a differently signed widget" \
  'app and Live Activity extension are signed by different teams.' \
  "$gate" "$wrong_team_app"

wrong_app_team=$(make_fixture "$test_root/wrong-app-team" iphoneos true OLDDMYTROTEAM)
expect_fail_with "signed iphoneos rejects an archive from the old Apple team" \
  'instead of expected team 3Z64QKNL54.' \
  "$gate" "$wrong_app_team"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
