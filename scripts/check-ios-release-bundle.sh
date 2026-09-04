#!/bin/sh
set -eu

usage() {
  cat >&2 <<EOF
Usage: $0 [--auto|--signed|--simulator] /absolute/path/to/SpyClash.app
       $0 [--auto|--signed] /absolute/path/to/SpyClash.xcarchive

  --auto       Require effective signed entitlements for iphoneos bundles and
               skip them for iphonesimulator bundles (default).
  --signed     Always require a valid device/archive signature, embedded
               provisioning profiles, and effective signed entitlements.
  --simulator  Explicitly skip signed-entitlement checks. Refuses iphoneos.
EOF
}

mode=auto
case "$#" in
  1)
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        usage
        exit 64
        ;;
    esac
    input=$1
    ;;
  2)
    case "$1" in
      --auto) mode=auto ;;
      --signed) mode=signed ;;
      --simulator) mode=simulator ;;
      *)
        usage
        exit 64
        ;;
    esac
    input=$2
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [ -d "$input/Products/Applications/SpyClash.app" ]; then
  app="$input/Products/Applications/SpyClash.app"
else
  app=$input
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_privacy="$root/SpyClash/Resources/PrivacyInfo.xcprivacy"
haptic_source="$root/SpyClash/Services/HapticManager.swift"
source_entitlements="$root/SpyClash/Resources/SpyClash.entitlements"
source_app_icon="$root/SpyClash/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
expected_team_identifier=$(awk '$1 == "DEVELOPMENT_TEAM:" { print $2; exit }' \
  "$root/project.yml")
expected_marketing_version=$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' \
  "$root/project.yml")
expected_build_number=$(awk '$1 == "CURRENT_PROJECT_VERSION:" { print $2; exit }' \
  "$root/project.yml")

fail() {
  echo "$1" >&2
  exit 1
}

effective_app_entitlements=
effective_widget_entitlements=
cleanup() {
  if [ -n "$effective_app_entitlements" ]; then
    rm -f "$effective_app_entitlements"
  fi
  if [ -n "$effective_widget_entitlements" ]; then
    rm -f "$effective_widget_entitlements"
  fi
}
trap cleanup EXIT HUP INT TERM

extract_effective_entitlements() {
  signed_bundle=$1
  signed_label=$2
  output_plist=$3

  if [ ! -f "$signed_bundle/embedded.mobileprovision" ]; then
    fail "$signed_label is missing embedded.mobileprovision."
  fi
  if ! codesign --verify --strict "$signed_bundle" >/dev/null 2>&1; then
    fail "$signed_label has an invalid or incomplete code signature."
  fi
  if ! signature_metadata=$(codesign -dvv "$signed_bundle" 2>&1); then
    fail "Unable to inspect the $signed_label code-signing identity."
  fi
  if printf '%s\n' "$signature_metadata" \
      | grep -Eq '^Signature=adhoc$|^TeamIdentifier=not set$'; then
    fail "$signed_label is ad-hoc signed instead of certificate-signed."
  fi
  if ! printf '%s\n' "$signature_metadata" \
      | grep -Eq '^Authority=Apple Distribution:'; then
    fail "$signed_label is not signed by an Apple Distribution identity."
  fi
  if ! printf '%s\n' "$signature_metadata" \
      | grep -Eq '^TeamIdentifier=[^[:space:]]+$'; then
    fail "$signed_label code signature is missing a TeamIdentifier."
  fi
  if ! codesign -d --entitlements :- "$signed_bundle" >"$output_plist" 2>/dev/null; then
    fail "Unable to read effective entitlements from the signed $signed_label."
  fi
  if ! plutil -lint "$output_plist" >/dev/null 2>&1; then
    fail "The signed $signed_label returned malformed effective entitlements."
  fi
}

require_identifier_entitlements() {
  entitlements_plist=$1
  expected_bundle_id=$2
  signed_label=$3
  signed_bundle=$4

  application_identifier=$(/usr/libexec/PlistBuddy \
    -c 'Print :application-identifier' "$entitlements_plist" 2>/dev/null || true)
  signed_team_identifier=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.team-identifier' "$entitlements_plist" 2>/dev/null || true)
  case "$application_identifier" in
    *."$expected_bundle_id") ;;
    *) fail "$signed_label effective application-identifier does not match $expected_bundle_id." ;;
  esac
  if [ -z "$signed_team_identifier" ]; then
    fail "$signed_label effective entitlements are missing com.apple.developer.team-identifier."
  fi
  signature_team_identifier=$(codesign -dvv "$signed_bundle" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' | head -n 1)
  if [ "$signed_team_identifier" != "$signature_team_identifier" ]; then
    fail "$signed_label effective team identifier does not match its code signature."
  fi

  printf '%s\n' "$signed_team_identifier"
}

if [ ! -d "$app" ] || [ ! -f "$app/Info.plist" ]; then
  echo "Release app bundle not found: $app" >&2
  exit 66
fi

if [ ! -f "$source_app_icon" ]; then
  fail "The 1024x1024 App Store icon source is missing."
fi
icon_properties=$(sips -g pixelWidth -g pixelHeight -g hasAlpha \
  "$source_app_icon" 2>/dev/null)
icon_width=$(printf '%s\n' "$icon_properties" | awk '/pixelWidth:/ { print $2 }')
icon_height=$(printf '%s\n' "$icon_properties" | awk '/pixelHeight:/ { print $2 }')
icon_has_alpha=$(printf '%s\n' "$icon_properties" | awk '/hasAlpha:/ { print $2 }')
if [ "$icon_width" != 1024 ] || [ "$icon_height" != 1024 ]; then
  fail "The App Store icon source must be exactly 1024x1024 pixels."
fi
if [ "$icon_has_alpha" != no ]; then
  fail "The App Store icon source must not contain an alpha channel."
fi

haptic_conflict_count=$(find "$root/SpyClash/Services" -maxdepth 1 -type f \
  -name 'HapticManager [0-9]*.swift' | wc -l | tr -d ' ')
if [ "$haptic_conflict_count" -ne 0 ]; then
  echo "Numbered HapticManager conflict copies remain in the release source tree." >&2
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
marketing_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
platform_name=$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$app/Info.plist" 2>/dev/null || true)
if [ "$bundle_id" != 'com.spyclash.ios' ] || [ -z "$marketing_version" ] || [ -z "$build_number" ]; then
  echo "Unexpected bundle metadata: id=$bundle_id version=$marketing_version build=$build_number" >&2
  exit 1
fi
if [ -z "$expected_marketing_version" ] || [ -z "$expected_build_number" ]; then
  fail "project.yml does not declare the expected marketing version and build number."
fi
if [ "$marketing_version" != "$expected_marketing_version" ] \
    || [ "$build_number" != "$expected_build_number" ]; then
  fail "Release artifact $marketing_version ($build_number) does not match project.yml $expected_marketing_version ($expected_build_number)."
fi
if [ ! -f "$app/$bundle_executable" ]; then
  echo "The compiled Release executable is missing." >&2
  exit 1
fi

live_activities=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsLiveActivities' "$app/Info.plist" 2>/dev/null || true)
widget="$app/PlugIns/SpyClashWidgets.appex"
if [ "$live_activities" != 'true' ] || [ ! -f "$widget/Info.plist" ]; then
  echo "The Release bundle is missing Live Activity support or its widget extension." >&2
  exit 1
fi
widget_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Info.plist")
widget_marketing_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget/Info.plist")
widget_build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget/Info.plist")
widget_point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget/Info.plist")
widget_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget/Info.plist")
if [ "$widget_id" != 'com.spyclash.ios.widgets' ] \
    || [ "$widget_marketing_version" != "$marketing_version" ] \
    || [ "$widget_build_number" != "$build_number" ] \
    || [ "$widget_point" != 'com.apple.widgetkit-extension' ] \
    || [ ! -f "$widget/$widget_executable" ]; then
  echo "Unexpected SpyClash Live Activity extension metadata." >&2
  exit 1
fi
aps_environment=$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$source_entitlements" 2>/dev/null || true)
if [ "$aps_environment" != '$(APS_ENVIRONMENT)' ]; then
  echo "The app entitlements do not bind aps-environment to the build configuration." >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' \
    "$source_entitlements" 2>/dev/null \
    | grep -Eq '^[[:space:]]*Default[[:space:]]*$'; then
  echo "The app entitlements do not declare Sign in with Apple as Default." >&2
  exit 1
fi

case "$mode:$platform_name" in
  auto:iphoneos|signed:*) require_signed_entitlements=true ;;
  auto:iphonesimulator|simulator:iphonesimulator) require_signed_entitlements=false ;;
  simulator:iphoneos)
    fail "Refusing to skip signed-entitlement checks for an iphoneos bundle."
    ;;
  auto:*)
    fail "Cannot identify DTPlatformName; rerun with --signed or --simulator."
    ;;
  simulator:*)
    fail "--simulator requires DTPlatformName=iphonesimulator."
    ;;
esac

if [ "$require_signed_entitlements" = true ]; then
  effective_app_entitlements=$(mktemp /tmp/spyclash-app-entitlements.XXXXXX)
  effective_widget_entitlements=$(mktemp /tmp/spyclash-widget-entitlements.XXXXXX)

  extract_effective_entitlements \
    "$app" "SpyClash app" "$effective_app_entitlements"
  app_team_identifier=$(require_identifier_entitlements \
    "$effective_app_entitlements" "$bundle_id" "SpyClash app" "$app")
  if [ -z "$expected_team_identifier" ]; then
    fail "project.yml does not declare the expected Apple development team."
  fi
  if [ "$app_team_identifier" != "$expected_team_identifier" ]; then
    fail "SpyClash app is signed by team $app_team_identifier instead of expected team $expected_team_identifier."
  fi

  signed_aps_environment=$(/usr/libexec/PlistBuddy \
    -c 'Print :aps-environment' "$effective_app_entitlements" 2>/dev/null || true)
  if [ "$signed_aps_environment" != production ]; then
    fail "SpyClash app effective entitlements must use aps-environment=production."
  fi
  app_get_task_allow=$(/usr/libexec/PlistBuddy \
    -c 'Print :get-task-allow' "$effective_app_entitlements" 2>/dev/null || true)
  if [ "$app_get_task_allow" != false ]; then
    fail "SpyClash app effective entitlements must set get-task-allow=false."
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' \
      "$effective_app_entitlements" 2>/dev/null \
      | grep -Eq '^[[:space:]]*Default[[:space:]]*$'; then
    fail "SpyClash app effective entitlements are missing Sign in with Apple Default."
  fi

  extract_effective_entitlements \
    "$widget" "SpyClash Live Activity extension" "$effective_widget_entitlements"
  widget_team_identifier=$(require_identifier_entitlements \
    "$effective_widget_entitlements" "$widget_id" \
    "SpyClash Live Activity extension" "$widget")
  if [ "$widget_team_identifier" != "$app_team_identifier" ]; then
    fail "SpyClash app and Live Activity extension are signed by different teams."
  fi
  widget_get_task_allow=$(/usr/libexec/PlistBuddy \
    -c 'Print :get-task-allow' "$effective_widget_entitlements" 2>/dev/null || true)
  if [ "$widget_get_task_allow" != false ]; then
    fail "SpyClash Live Activity extension effective entitlements must set get-task-allow=false."
  fi
  entitlement_gate_summary="effective signed entitlements verified (aps-environment=$signed_aps_environment, Sign in with Apple=Default)"
else
  entitlement_gate_summary="simulator bundle; effective signed-entitlement checks skipped"
fi

if grep -Eq 'AVAudio|AudioServices|SystemSound|UNNotificationSound|SoundCue|playSound|sound:|audioPolicy:|AuthCinematicSoundPlayer' "$haptic_source"; then
  echo "HapticManager contains an audio playback path." >&2
  exit 1
fi
if grep -R -E -n --include='*.swift' \
    'AVAudio|AudioServices|SystemSound|UNNotificationSound|SoundCue|playSound|sound:|audioPolicy:|AuthCinematicSoundPlayer' \
    "$root/SpyClash" >/dev/null; then
  echo "An audio playback path remains in the Swift source tree." >&2
  exit 1
fi

source_audio_count=$(find "$root/SpyClash" -type f \( \
  -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o \
  -iname '*.aif' -o -iname '*.aiff' -o -iname '*.caf' -o \
  -iname '*.aac' -o -iname '*.flac' -o -iname '*.ogg' \
  \) | wc -l | tr -d ' ')
bundle_audio_count=$(find "$app" -type f \( \
  -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o \
  -iname '*.aif' -o -iname '*.aiff' -o -iname '*.caf' -o \
  -iname '*.aac' -o -iname '*.flac' -o -iname '*.ogg' \
  \) | wc -l | tr -d ' ')
if [ "$source_audio_count" -ne 0 ] || [ "$bundle_audio_count" -ne 0 ]; then
  echo "SpyClash must contain no audio files; found source=$source_audio_count bundle=$bundle_audio_count." >&2
  exit 1
fi
if strings "$app/$bundle_executable" | grep -E 'com\.spyclash\.interface-audio|spyclash\.interface-sounds|ui-player-join\.wav|apple-fragment-lock\.wav' >/dev/null; then
  echo "The compiled Release executable still contains legacy audio markers." >&2
  exit 1
fi

privacy_count=$(find "$app" -maxdepth 1 -type f -name 'PrivacyInfo.xcprivacy' | wc -l | tr -d ' ')
if [ "$privacy_count" -ne 1 ] || [ ! -f "$app/PrivacyInfo.xcprivacy" ]; then
  echo "Expected exactly one root PrivacyInfo.xcprivacy in the Release bundle." >&2
  exit 1
fi
plutil -lint "$app/Info.plist" "$app/PrivacyInfo.xcprivacy" >/dev/null
bundled_privacy_manifests=$(find "$app" -type f -name 'PrivacyInfo.xcprivacy' -print)
printf '%s\n' "$source_privacy" "$bundled_privacy_manifests" \
  | while IFS= read -r inspected_privacy_manifest
do
  [ -n "$inspected_privacy_manifest" ] || continue
  if ! plutil -lint "$inspected_privacy_manifest" >/dev/null; then
    echo "Could not validate a bundled privacy manifest: $inspected_privacy_manifest" >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy \
      -c 'Print :NSPrivacyCollectedDataTypes' \
      "$inspected_privacy_manifest" 2>/dev/null \
      | grep -F 'NSPrivacyCollectedDataTypePurchaseHistory' >/dev/null; then
    if [ "$inspected_privacy_manifest" != "$source_privacy" ] && [ "$inspected_privacy_manifest" != "$app/PrivacyInfo.xcprivacy" ]; then
      echo "Purchase History must not be declared by the Live Activity extension or an unrelated bundled component." >&2
      exit 1
    fi
  elif [ "$inspected_privacy_manifest" = "$source_privacy" ] || [ "$inspected_privacy_manifest" = "$app/PrivacyInfo.xcprivacy" ]; then
    echo "Apple IAP Release must declare Purchase History in its root privacy manifest." >&2
    exit 1
  fi
done
if ! cmp -s "$source_privacy" "$app/PrivacyInfo.xcprivacy"; then
  echo "Bundled PrivacyInfo.xcprivacy differs from the reviewed source manifest." >&2
  exit 1
fi

storekit_count=$(find "$app" -type f -name '*.storekit' | wc -l | tr -d ' ')
if [ "$storekit_count" -ne 0 ]; then
  echo "Local StoreKit configuration leaked into the Release bundle." >&2
  exit 1
fi

inspection_executable="$app/$bundle_executable"
# Xcode's Simulator Debug builds place application code in a separate dylib.
# Signed device/Release validation still inspects the actual executable.
if [ "$platform_name" = iphonesimulator ] && [ -f "$app/$bundle_executable.debug.dylib" ]; then
  inspection_executable="$app/$bundle_executable.debug.dylib"
fi
linked_frameworks=$(otool -L "$inspection_executable") || {
  echo "Could not inspect linked frameworks in the Release executable." >&2
  exit 1
}
if ! printf '%s\n' "$linked_frameworks" | grep -F 'StoreKit.framework' >/dev/null; then
  echo "Apple IAP Release must link StoreKit.framework." >&2
  exit 1
fi

if ! strings "$inspection_executable" | grep -F 'com.spyclash.ios.limitless.weekly' >/dev/null; then
  echo "Apple IAP Release is missing the expected LIMITLESS product." >&2
  exit 1
fi

commerce_scan_status=0
LC_ALL=C grep -r -a -F -l \
    -e 'prior provider billing activity' \
    -e 'historical provider records created outside this iOS release' \
    -e 'historical web-billing records' \
    -e 'historical transaction records' \
    -e 'provider-managed billing agreement' \
    -e 'has no checkout' \
    -e 'Separate historical agreements created outside this release' \
    -e 'Stripe' \
    -e 'VERSIÓN ACTUAL PARA IOS' \
    -e 'históricos de transacciones' \
    -e 'acuerdo de facturación' \
    -e 'ТЕКУЩАЯ ВЕРСИЯ ДЛЯ IOS' \
    -e 'исторические записи транзакций' \
    -e 'соглашение о выставлении счетов' \
    -e 'ПОТОЧНА ВЕРСІЯ ДЛЯ IOS' \
    -e 'історичні записи транзакцій' \
    -e 'угода про виставлення рахунків' \
    -- "$app" >/dev/null || commerce_scan_status=$?
case "$commerce_scan_status" in
  0)
    echo "The signed Release bundle still contains retired commerce copy." >&2
    exit 1
    ;;
  1) ;;
  *)
    echo "Could not inspect the signed Release bundle for retired commerce copy." >&2
    exit 1
    ;;
esac

echo "iOS Release bundle gate passed: $bundle_id $marketing_version ($build_number), 1024px opaque App Store icon present, Live Activity extension embedded, $entitlement_gate_summary, no audio files or playback paths, privacy manifest exact with Purchase History, Apple StoreKit and expected LIMITLESS product present, no local StoreKit configuration or retired commerce copy."
