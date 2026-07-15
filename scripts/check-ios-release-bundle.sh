#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/to/SpyClash.app" >&2
  exit 64
fi

app=$1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_privacy="$root/SpyClash/Resources/PrivacyInfo.xcprivacy"
source_sounds="$root/SpyClash/Resources/Sounds"
haptic_source="$root/SpyClash/Services/HapticManager.swift"
source_entitlements="$root/SpyClash/Resources/SpyClash.entitlements"

expected_sounds='apple-access-surge.wav
apple-fragment-lock.wav
ui-allow.wav
ui-click.wav
ui-copy-confirm.wav
ui-countdown-go.wav
ui-countdown-tick.wav
ui-denied.wav
ui-echo-blip.wav
ui-game-start.wav
ui-hard-deny.wav
ui-holographic-tick.wav
ui-navigation-shift.wav
ui-player-join.wav
ui-player-leave.wav
ui-qr-card-flip.wav
ui-ready-lock.wav
ui-result-detectives.wav
ui-result-spy.wav
ui-role-reveal.wav
ui-secret-reveal.wav
ui-success.wav
ui-toggle-off.wav
ui-toggle-on.wav
ui-turn-pass.wav
ui-vote-cast.wav
ui-vote-locked.wav'

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
aps_environment=$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$source_entitlements" 2>/dev/null || true)
if [ "$aps_environment" != '$(APS_ENVIRONMENT)' ]; then
  echo "The app entitlements do not bind aps-environment to the build configuration." >&2
  exit 1
fi

if ! grep -Fq 'import AVFoundation' "$haptic_source" \
    || ! grep -Fq 'private let interfaceSoundEngine = InterfaceSoundEngine()' "$haptic_source" \
    || ! grep -Fq 'private final class InterfaceSoundEngine' "$haptic_source" \
    || ! grep -Fq 'interfaceSoundEngine.play(cue)' "$haptic_source" \
    || ! grep -Fq 'spyclash.interface-sounds.recovered-after-noop-v1' "$haptic_source"; then
  echo "The reviewed source does not contain the active interface-audio engine and recovery migration." >&2
  exit 1
fi
if grep -Fq 'SPYCLASH_LEGACY_AUDIO' "$haptic_source" \
    || grep -Fq 'func playSound(_ cue: SoundCue) {}' "$haptic_source" \
    || grep -Fq 'UserDefaults.standard.set(false, forKey: Self.interfaceSoundsEnabledKey)' "$haptic_source"; then
  echo "HapticManager contains a release-blocking audio bypass or no-op." >&2
  exit 1
fi
if ! strings "$app/$bundle_executable" | grep -Fq 'com.spyclash.interface-audio' \
    || ! strings "$app/$bundle_executable" | grep -Fq 'spyclash.interface-sounds.recovered-after-noop-v1'; then
  echo "The compiled Release executable does not contain the active audio-engine markers." >&2
  exit 1
fi

source_sound_count=$(find "$source_sounds" -maxdepth 1 -type f -name '*.wav' | wc -l | tr -d ' ')
bundle_sound_count=$(find "$app" -maxdepth 1 -type f -name '*.wav' | wc -l | tr -d ' ')
if [ "$source_sound_count" -ne 27 ] || [ "$bundle_sound_count" -ne 27 ]; then
  echo "Expected exactly 27 source and 27 bundled WAV files; found source=$source_sound_count bundle=$bundle_sound_count." >&2
  exit 1
fi

for name in $expected_sounds; do
  source_file="$source_sounds/$name"
  bundle_file="$app/$name"
  if [ ! -f "$source_file" ] || [ ! -f "$bundle_file" ]; then
    echo "Required Release sound is missing: $name" >&2
    exit 1
  fi
  if ! cmp -s "$source_file" "$bundle_file"; then
    echo "Bundled sound differs from the reviewed source: $name" >&2
    exit 1
  fi
  audio_offset=$(afinfo "$source_file" | awk '/audio data file offset:/ { print $5; exit }')
  if [ -z "$audio_offset" ] || ! od -An -t u2 -j "$audio_offset" "$source_file" \
      | awk '{ for (i = 1; i <= NF; i++) if ($i != 0) found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "Sound has no non-zero PCM samples: $name" >&2
    exit 1
  fi
done

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

echo "iOS Release bundle gate passed: $bundle_id $marketing_version ($build_number), Live Activity extension embedded, 27 audible WAV files, privacy manifest exact, no .storekit."
