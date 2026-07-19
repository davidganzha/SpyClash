#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/to/SpyClash.app" >&2
  exit 64
fi

app=$1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_privacy="$root/SpyClash/Resources/PrivacyInfo.xcprivacy"
haptic_source="$root/SpyClash/Services/HapticManager.swift"
notification_source="$root/SpyClash/Services/PushNotificationCoordinator.swift"
push_event_source="$root/base44/functions/pushNotificationAction/push-events.ts"
source_entitlements="$root/SpyClash/Resources/SpyClash.entitlements"

if [ ! -d "$app" ] || [ ! -f "$app/Info.plist" ]; then
  echo "Release app bundle not found: $app" >&2
  exit 66
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
if [ "$bundle_id" != 'com.spyclash.app' ] || [ -z "$marketing_version" ] || [ -z "$build_number" ]; then
  echo "Unexpected bundle metadata: id=$bundle_id version=$marketing_version build=$build_number" >&2
  exit 1
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
widget_point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget/Info.plist")
widget_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget/Info.plist")
if [ "$widget_id" != 'com.spyclash.app.widgets' ] \
    || [ "$widget_point" != 'com.apple.widgetkit-extension' ] \
    || [ ! -f "$widget/$widget_executable" ]; then
  echo "Unexpected SpyClash Live Activity extension metadata." >&2
  exit 1
fi

app_profile="$app/embedded.mobileprovision"
widget_profile="$widget/embedded.mobileprovision"
if [ ! -f "$app_profile" ] || [ ! -f "$widget_profile" ]; then
  echo "The exported Release bundle is missing an App Store provisioning profile." >&2
  exit 1
fi

profile_work=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-release-profile.XXXXXX")
trap 'rm -rf "$profile_work"' EXIT HUP INT TERM
if ! security cms -D -i "$app_profile" > "$profile_work/app.plist" \
    || ! security cms -D -i "$widget_profile" > "$profile_work/widget.plist"; then
  echo "Unable to decode the exported App Store provisioning profiles." >&2
  exit 1
fi

app_profile_environment=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$profile_work/app.plist" 2>/dev/null || true)
app_profile_debug=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$profile_work/app.plist" 2>/dev/null || true)
app_profile_beta=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:beta-reports-active' "$profile_work/app.plist" 2>/dev/null || true)
widget_profile_debug=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$profile_work/widget.plist" 2>/dev/null || true)
widget_profile_beta=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:beta-reports-active' "$profile_work/widget.plist" 2>/dev/null || true)
if [ "$app_profile_environment" != 'production' ] \
    || [ "$app_profile_debug" != 'false' ] \
    || [ "$app_profile_beta" != 'true' ] \
    || [ "$widget_profile_debug" != 'false' ] \
    || [ "$widget_profile_beta" != 'true' ]; then
  echo "The exported bundle is not provisioned for App Store distribution." >&2
  exit 1
fi

if ! codesign --verify --strict --deep "$app" >/dev/null 2>&1 \
    || ! codesign -dvv "$app" 2>&1 | grep -Fq 'Authority=Apple Distribution:'; then
  echo "The exported Release bundle does not have a valid Apple Distribution signature." >&2
  exit 1
fi

aps_environment=$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$source_entitlements" 2>/dev/null || true)
if [ "$aps_environment" != '$(APS_ENVIRONMENT)' ]; then
  echo "The app entitlements do not bind aps-environment to the build configuration." >&2
  exit 1
fi

if ! grep -Fq 'import CoreHaptics' "$haptic_source" \
    || ! grep -Fq 'engine.playsHapticsOnly = true' "$haptic_source"; then
  echo "HapticManager is missing the reviewed haptics-only engine." >&2
  exit 1
fi
if grep -R -E --include='*.swift' \
    'AVAudio(Session|Player|Engine|Recorder)|AudioServices|SystemSound|SoundCue|InterfaceSoundEngine|playSound|AuthCinematicSoundPlayer' \
    "$root/SpyClash" >/dev/null 2>&1; then
  echo "The iOS source still contains an audio playback path." >&2
  exit 1
fi
if grep -Fq '.sound' "$notification_source" \
    || grep -E 'sound[[:space:]]*:' "$push_event_source" >/dev/null 2>&1; then
  echo "Push notifications still request or deliver sound." >&2
  exit 1
fi
if strings "$app/$bundle_executable" | grep -E 'com\.spyclash\.interface-audio|spyclash\.interface-sounds' >/dev/null 2>&1; then
  echo "The compiled Release executable still contains removed audio-engine markers." >&2
  exit 1
fi

source_audio_count=$(find "$root/SpyClash" -type f \( \
  -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o \
  -iname '*.caf' -o -iname '*.aif' -o -iname '*.aiff' \) | wc -l | tr -d ' ')
bundle_audio_count=$(find "$app" -type f \( \
  -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o \
  -iname '*.caf' -o -iname '*.aif' -o -iname '*.aiff' \) | wc -l | tr -d ' ')
if [ "$source_audio_count" -ne 0 ] || [ "$bundle_audio_count" -ne 0 ]; then
  echo "Expected no source or bundled audio files; found source=$source_audio_count bundle=$bundle_audio_count." >&2
  exit 1
fi

privacy_count=$(find "$app" -maxdepth 1 -type f -name 'PrivacyInfo.xcprivacy' | wc -l | tr -d ' ')
if [ "$privacy_count" -ne 1 ] || [ ! -f "$app/PrivacyInfo.xcprivacy" ]; then
  echo "Expected exactly one root PrivacyInfo.xcprivacy in the Release bundle." >&2
  exit 1
fi
plutil -lint "$app/Info.plist" "$app/PrivacyInfo.xcprivacy" >/dev/null
if ! cmp -s "$source_privacy" "$app/PrivacyInfo.xcprivacy"; then
  echo "Bundled PrivacyInfo.xcprivacy differs from the reviewed source manifest." >&2
  exit 1
fi

storekit_count=$(find "$app" -type f -name '*.storekit' | wc -l | tr -d ' ')
if [ "$storekit_count" -ne 0 ]; then
  echo "Local StoreKit configuration leaked into the Release bundle." >&2
  exit 1
fi

echo "iOS Release bundle gate passed: $bundle_id $marketing_version ($build_number), Apple Distribution signing and production APNs exact, Live Activity extension embedded, haptics-only feedback, no bundled audio, privacy manifest exact, no .storekit."
