#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
gate="$root/scripts/check-ios-release-bundle.sh"
mock_bin="$root/scripts/tests/fixtures"
test_root=$(mktemp -d /tmp/spyclash-release-gate-tests.XXXXXX)
expected_marketing_version=$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' \
  "$root/project.yml")
expected_build_number=$(awk '$1 == "CURRENT_PROJECT_VERSION:" { print $2; exit }' \
  "$root/project.yml")

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
    plist_add "$output" 'Add :com.apple.developer.game-center bool true'
  fi
  plist_add "$output" 'Add :get-task-allow bool false'
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
  plist_add "$app/Info.plist" "Add :CFBundleShortVersionString string $expected_marketing_version"
  plist_add "$app/Info.plist" "Add :CFBundleVersion string $expected_build_number"
  plist_add "$app/Info.plist" 'Add :CFBundleExecutable string SpyClash'
  plist_add "$app/Info.plist" "Add :DTPlatformName string $platform"
  plist_add "$app/Info.plist" 'Add :NSSupportsLiveActivities bool true'
  touch "$app/SpyClash"
  printf '%s\n' 'com.spyclash.ios.limitless.weekly' >>"$app/SpyClash"
  touch "$app/.mock-storekit-linkage"
  chmod +x "$app/SpyClash"
  cp "$root/SpyClash/Resources/PrivacyInfo.xcprivacy" "$app/PrivacyInfo.xcprivacy"

  plutil -create xml1 "$widget/Info.plist"
  plist_add "$widget/Info.plist" 'Add :CFBundleIdentifier string com.spyclash.ios.widgets'
  plist_add "$widget/Info.plist" "Add :CFBundleShortVersionString string $expected_marketing_version"
  plist_add "$widget/Info.plist" "Add :CFBundleVersion string $expected_build_number"
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

make_public_fixture() {
  public_app=$(make_fixture "$@")
  plist_add "$public_app/Info.plist" 'Add :SpyClashBackendMode string supabase-public'
  plist_add "$public_app/Info.plist" 'Add :CFBundleURLTypes array'
  plist_add "$public_app/Info.plist" 'Add :CFBundleURLTypes:0 dict'
  plist_add "$public_app/Info.plist" 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array'
  plist_add "$public_app/Info.plist" 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string spyclash'
  cp "$root/release/SupabasePublicConfiguration.json" "$public_app/SupabasePublicConfiguration.json"
  printf '%s\n' "$public_app"
}

change_public_config() {
  python3 - "$1/SupabasePublicConfiguration.json" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
value = json.loads(path.read_text())
value[sys.argv[2]] = json.loads(sys.argv[3])
path.write_text(json.dumps(value, indent=2) + "\n")
PY
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
candidate_app=$(make_fixture "$test_root/candidate" iphoneos true)
plist_add "$candidate_app/Info.plist" 'Add :SpyClashBackendMode string supabase-main-candidate'
expect_fail_with "signed main candidate cannot distribute the test backend" \
  'restricted to internal testing' "$gate" --signed "$candidate_app"
public_app=$(make_public_fixture "$test_root/public" iphoneos true)
expect_pass "explicit public Supabase package passes signed checks" "$gate" --signed "$public_app"
expect_pass "public package result does not claim backend readiness" \
  /bin/sh -c '"$1" --signed "$2" | grep -F "backend deployment/readiness not verified"' \
  sh "$gate" "$public_app"
public_simulator=$(make_public_fixture "$test_root/public-simulator" iphonesimulator false)
expect_pass "public Supabase package can be inspected without signing in Simulator mode" \
  "$gate" --simulator "$public_simulator"

missing_public_config=$(make_public_fixture "$test_root/public-missing" iphoneos true)
rm "$missing_public_config/SupabasePublicConfiguration.json"
expect_fail_with "public Supabase requires its explicit resource" \
  'missing its explicit production configuration' "$gate" --signed "$missing_public_config"

malformed_public_config=$(make_public_fixture "$test_root/public-malformed" iphoneos true)
printf '%s\n' '{' >"$malformed_public_config/SupabasePublicConfiguration.json"
expect_fail_with "public Supabase rejects malformed configuration" \
  'configuration cannot be validated' "$gate" --signed "$malformed_public_config"

wrong_public_backend=$(make_public_fixture "$test_root/public-wrong-backend" iphoneos true)
change_public_config "$wrong_public_backend" backendURL '"https://other-project.supabase.co"'
expect_fail_with "public Supabase rejects an unintended backend" \
  'selects an unexpected backend' "$gate" --signed "$wrong_public_backend"

secret_public_key=$(make_public_fixture "$test_root/public-secret-key" iphoneos true)
change_public_config "$secret_public_key" publishableKey '"sb_secret_fixture"'
expect_fail_with "public Supabase rejects a secret key" \
  'must use a publishable key' "$gate" --signed "$secret_public_key"

changed_public_key=$(make_public_fixture "$test_root/public-changed-key" iphoneos true)
change_public_config "$changed_public_key" publishableKey '"sb_publishable_unreviewed"'
expect_fail_with "public Supabase retains the candidate backend credential" \
  'differs from the candidate beyond full account deletion' "$gate" --signed "$changed_public_key"

no_public_deletion=$(make_public_fixture "$test_root/public-no-deletion" iphoneos true)
change_public_config "$no_public_deletion" mainAccountDeletionEnabled false
expect_fail_with "public Supabase cannot disable account deletion" \
  'must enable full account deletion' "$gate" --signed "$no_public_deletion"

string_public_deletion=$(make_public_fixture "$test_root/public-string-deletion" iphoneos true)
change_public_config "$string_public_deletion" mainAccountDeletionEnabled '"true"'
expect_fail_with "public Supabase requires a boolean deletion capability" \
  'must enable full account deletion' "$gate" --signed "$string_public_deletion"

for capability in appleSignInEnabled googleSignInEnabled gameCenterSignInEnabled permitsLegacyBilling; do
  disabled_public_capability=$(make_public_fixture "$test_root/public-disabled-$capability" iphoneos true)
  change_public_config "$disabled_public_capability" "$capability" false
  capability_error="must retain Apple, Google and native billing"
  if [ "$capability" = gameCenterSignInEnabled ]; then capability_error="must enable the reviewed Game Center flow"; fi
  expect_fail_with "public Supabase retains $capability" \
    "$capability_error" "$gate" --signed "$disabled_public_capability"
done

unexpected_public_push=$(make_public_fixture "$test_root/public-unexpected-push" iphoneos true)
change_public_config "$unexpected_public_push" permitsLegacyPush true
expect_fail_with "public Supabase does not silently enable unverified push" \
  'unexpectedly enables legacy push' "$gate" --signed "$unexpected_public_push"

wrong_public_otp=$(make_public_fixture "$test_root/public-wrong-otp" iphoneos true)
change_public_config "$wrong_public_otp" emailOTPLength 8
expect_fail_with "public Supabase preserves six-digit email verification" \
  'must retain six-digit email verification' "$gate" --signed "$wrong_public_otp"

changed_public_bytes=$(make_public_fixture "$test_root/public-changed-bytes" iphoneos true)
printf '\n' >>"$changed_public_bytes/SupabasePublicConfiguration.json"
expect_fail_with "public Supabase config must match reviewed source bytes" \
  'differs from the reviewed source' "$gate" --signed "$changed_public_bytes"

wrong_public_callback=$(make_public_fixture "$test_root/public-wrong-callback" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 spyclash-supabasetest' \
  "$wrong_public_callback/Info.plist" >/dev/null
expect_fail_with "public Supabase retains the original callback scheme" \
  'must retain the original spyclash callback scheme' "$gate" --signed "$wrong_public_callback"

for leaked_config in SupabaseMainCandidateConfiguration.json SupabaseAppConfiguration.json BackendAllowlist.json; do
  public_leak=$(make_public_fixture "$test_root/public-leaked-$leaked_config" iphoneos true)
  printf '%s\n' '{}' >"$public_leak/PlugIns/SpyClashWidgets.appex/$leaked_config"
  expect_fail_with "public Supabase rejects nested $leaked_config" \
    'contains a candidate, staging or lab configuration' "$gate" --signed "$public_leak"
done

public_internal_only=$(make_public_fixture "$test_root/public-internal-only" iphoneos true)
plist_add "$public_internal_only/Info.plist" 'Add :TFInternalTestingOnly bool true'
expect_fail_with "public Supabase rejects an internal-only TestFlight artifact" \
  'internal-only TestFlight bundle cannot pass' "$gate" --signed "$public_internal_only"
legacy_internal_only=$(make_fixture "$test_root/legacy-internal-only" iphoneos true)
plist_add "$legacy_internal_only/Info.plist" 'Add :TFInternalTestingOnly bool true'
expect_fail_with "legacy public gate also rejects internal-only TestFlight artifacts" \
  'internal-only TestFlight bundle cannot pass' "$gate" --signed "$legacy_internal_only"

unknown_backend=$(make_fixture "$test_root/unknown-backend" iphoneos true)
plist_add "$unknown_backend/Info.plist" 'Add :SpyClashBackendMode string unexpected'
expect_fail_with "unknown backend mode cannot bypass either public route" \
  'unsupported backend mode' "$gate" --signed "$unknown_backend"
legacy_public_leak=$(make_fixture "$test_root/legacy-public-config" iphoneos true)
cp "$root/release/SupabasePublicConfiguration.json" "$legacy_public_leak/SupabasePublicConfiguration.json"
expect_fail_with "legacy Base44 remains isolated from the new public configuration" \
  'Legacy Base44 release contains a Supabase or lab configuration' "$gate" --signed "$legacy_public_leak"

debug_dylib_app=$(make_fixture "$test_root/debug-dylib" iphonesimulator false)
: >"$debug_dylib_app/SpyClash"
printf '%s\n' 'com.spyclash.ios.limitless.weekly' >"$debug_dylib_app/SpyClash.debug.dylib"
expect_pass "Simulator Debug checks the application dylib instead of the launch shim" "$gate" "$debug_dylib_app"

expect_pass "auto validates effective entitlements for iphoneos" "$gate" "$signed_app"

development_push_app=$(make_fixture "$test_root/development-push" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :aps-environment development' \
  "$development_push_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed Release rejects development APNs entitlement" \
  'effective entitlements must use aps-environment=production.' \
  "$gate" "$development_push_app"

development_signature_app=$(make_fixture "$test_root/development-signature" iphoneos true)
touch "$development_signature_app/.mock-development-signature"
expect_fail_with "signed Release rejects Apple Development identity" \
  'is not signed by an Apple Distribution identity.' \
  "$gate" "$development_signature_app"

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
  'effective entitlements must use aps-environment=production.' \
  "$gate" "$missing_push_app"

debuggable_app=$(make_fixture "$test_root/debuggable" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :get-task-allow true' \
  "$debuggable_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed Release rejects get-task-allow=true" \
  'effective entitlements must set get-task-allow=false.' \
  "$gate" "$debuggable_app"

debuggable_widget_app=$(make_fixture "$test_root/debuggable-widget" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :get-task-allow true' \
  "$debuggable_widget_app/PlugIns/SpyClashWidgets.appex/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed Release rejects a debuggable widget" \
  'Live Activity extension effective entitlements must set get-task-allow=false.' \
  "$gate" "$debuggable_widget_app"

stale_build_app=$(make_fixture "$test_root/stale-build" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' \
  "$stale_build_app/Info.plist" >/dev/null
expect_fail_with "gate rejects an artifact that does not match project.yml" \
  'does not match project.yml' \
  "$gate" "$stale_build_app"

widget_version_app=$(make_fixture "$test_root/widget-version" iphoneos true)
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' \
  "$widget_version_app/PlugIns/SpyClashWidgets.appex/Info.plist" >/dev/null
expect_fail_with "gate rejects mismatched app and widget versions" \
  'Unexpected SpyClash Live Activity extension metadata.' \
  "$gate" "$widget_version_app"

missing_sign_in_app=$(make_fixture "$test_root/missing-sign-in" iphoneos true)
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.applesignin' \
  "$missing_sign_in_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "signed iphoneos rejects missing Sign in with Apple" \
  'effective entitlements are missing Sign in with Apple Default.' \
  "$gate" "$missing_sign_in_app"

missing_game_center_app=$(make_public_fixture "$test_root/missing-game-center" iphoneos true)
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.game-center' \
  "$missing_game_center_app/.mock-entitlements.plist" >/dev/null
expect_fail_with "public signed iphoneos rejects missing Game Center" \
  'effective entitlements are missing Game Center.' \
  "$gate" "$missing_game_center_app"

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

storekit_config_app=$(make_fixture "$test_root/storekit-config" iphoneos true)
touch "$storekit_config_app/Leaked.storekit"
expect_fail_with "gate rejects a leaked StoreKit configuration" \
  'Local StoreKit configuration leaked into the Release bundle.' \
  "$gate" "$storekit_config_app"

storekit_linkage_app=$(make_fixture "$test_root/storekit-linkage" iphoneos true)
unlink "$storekit_linkage_app/.mock-storekit-linkage"
expect_fail_with "gate rejects missing StoreKit framework linkage" \
  'Apple IAP Release must link StoreKit.framework.' \
  "$gate" "$storekit_linkage_app"

iap_marker_app=$(make_fixture "$test_root/iap-marker" iphoneos true)
: >"$iap_marker_app/SpyClash"
expect_fail_with "gate rejects missing native IAP product" \
  'Apple IAP Release is missing the expected LIMITLESS product.' \
  "$gate" "$iap_marker_app"

purchase_history_app=$(make_fixture "$test_root/purchase-history" iphoneos true)
/usr/libexec/PlistBuddy \
  -c 'Delete :NSPrivacyCollectedDataTypes:0' \
  "$purchase_history_app/PrivacyInfo.xcprivacy" >/dev/null
expect_fail_with "gate requires Purchase History for Apple IAP" \
  'Apple IAP Release must declare Purchase History in its root privacy manifest.' \
  "$gate" "$purchase_history_app"

nested_purchase_history_app=$(make_fixture "$test_root/nested-purchase-history" iphoneos true)
nested_purchase_history_manifest="$nested_purchase_history_app/PlugIns/SpyClashWidgets.appex/PrivacyInfo.xcprivacy"
cp "$root/SpyClash/Resources/PrivacyInfo.xcprivacy" "$nested_purchase_history_manifest"
/usr/libexec/PlistBuddy \
  -c 'Set :NSPrivacyCollectedDataTypes:0:NSPrivacyCollectedDataType NSPrivacyCollectedDataTypePurchaseHistory' \
  "$nested_purchase_history_manifest" >/dev/null
expect_fail_with "gate rejects Purchase History in a nested privacy manifest" \
  'Purchase History must not be declared by the Live Activity extension or an unrelated bundled component.' \
  "$gate" "$nested_purchase_history_app"

commerce_case=0
for retired_commerce_marker in \
  'prior provider billing activity' \
  'historical provider records created outside this iOS release' \
  'historical web-billing records' \
  'historical transaction records' \
  'provider-managed billing agreement' \
  'has no checkout' \
  'Separate historical agreements created outside this release' \
  'Stripe' \
  'VERSIÓN ACTUAL PARA IOS' \
  'históricos de transacciones' \
  'acuerdo de facturación' \
  'ТЕКУЩАЯ ВЕРСИЯ ДЛЯ IOS' \
  'исторические записи транзакций' \
  'соглашение о выставлении счетов' \
  'ПОТОЧНА ВЕРСІЯ ДЛЯ IOS' \
  'історичні записи транзакцій' \
  'угода про виставлення рахунків'
do
  commerce_case=$((commerce_case + 1))
  commerce_app=$(make_fixture "$test_root/commerce-$commerce_case" iphoneos true)
  printf '%s\n' "$retired_commerce_marker" >>"$commerce_app/SpyClash"
  expect_fail_with "gate rejects retired commerce marker $commerce_case" \
    'The signed Release bundle still contains retired commerce copy.' \
    "$gate" "$commerce_app"
done

noncommerce_app=$(make_fixture "$test_root/noncommerce-subscription-plan" iphoneos true)
printf '%s\n' \
  'presence_subscription' \
  'GameStartPlan' \
  'reconcileGameRoomRealtimeSubscription' \
  >>"$noncommerce_app/SpyClash"
expect_pass "gate allows non-commerce subscription and plan identifiers" \
  "$gate" "$noncommerce_app"

grep_error_app=$(make_fixture "$test_root/grep-error" iphoneos true)
touch "$grep_error_app/unreadable-commerce-scan-fixture"
chmod 000 "$grep_error_app/unreadable-commerce-scan-fixture"
expect_fail_with "gate fails closed when commerce-copy inspection errors" \
  'Could not inspect the signed Release bundle for retired commerce copy.' \
  "$gate" "$grep_error_app"
chmod 600 "$grep_error_app/unreadable-commerce-scan-fixture"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
