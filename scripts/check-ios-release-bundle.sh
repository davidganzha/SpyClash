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
if [ "$bundle_id" != 'com.spyclash.ios' ] || [ -z "$marketing_version" ] || [ -z "$build_number" ]; then
  echo "Unexpected bundle metadata: id=$bundle_id version=$marketing_version build=$build_number" >&2
  exit 1
fi
if [ ! -f "$app/$bundle_executable" ]; then
  echo "The compiled Release executable is missing." >&2
  exit 1
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
if ! cmp -s "$source_privacy" "$app/PrivacyInfo.xcprivacy"; then
  echo "Bundled PrivacyInfo.xcprivacy differs from the reviewed source manifest." >&2
  exit 1
fi

storekit_count=$(find "$app" -type f -name '*.storekit' | wc -l | tr -d ' ')
if [ "$storekit_count" -ne 0 ]; then
  echo "Local StoreKit configuration leaked into the Release bundle." >&2
  exit 1
fi

echo "iOS Release bundle gate passed: $bundle_id $marketing_version ($build_number), no audio files or playback paths, privacy manifest exact, no .storekit."
