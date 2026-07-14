#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/to/SpyClash.app" >&2
  exit 64
fi

app=$1
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sounds="$root/SpyClash/Resources/Sounds"
haptic_manager="$root/SpyClash/Services/HapticManager.swift"
source_privacy="$root/SpyClash/Resources/PrivacyInfo.xcprivacy"

if [ ! -d "$app" ] || [ ! -f "$app/Info.plist" ]; then
  echo "Release app bundle not found: $app" >&2
  exit 66
fi

expected_sounds='
apple-access-surge.wav
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
ui-vote-locked.wav
'

source_count=$(find "$sounds" -type f -name '*.wav' | wc -l | tr -d ' ')
bundle_count=$(find "$app" -type f -name '*.wav' | wc -l | tr -d ' ')
if [ "$source_count" -ne 27 ] || [ "$bundle_count" -ne 27 ]; then
  echo "Expected 27 WAV files in source and bundle; found source=$source_count bundle=$bundle_count." >&2
  exit 1
fi

printf '%s\n' "$expected_sounds" | while IFS= read -r name; do
  [ -n "$name" ] || continue
  source_file="$sounds/$name"
  bundle_file="$app/$name"
  if [ ! -f "$source_file" ] || [ ! -f "$bundle_file" ]; then
    echo "Missing required sound: $name" >&2
    exit 1
  fi
  if ! cmp -s "$source_file" "$bundle_file"; then
    echo "Bundled sound differs from source: $name" >&2
    exit 1
  fi
  peak=$(od -An -v -t d2 -j 44 "$source_file" | awk '
    { for (i = 1; i <= NF; i += 1) { value = $i < 0 ? -$i : $i; if (value > maximum) maximum = value } }
    END { print maximum + 0 }
  ')
  if [ "$peak" -eq 0 ]; then
    echo "Sound contains no non-zero PCM samples: $name" >&2
    exit 1
  fi
done

if ! grep -Fq 'private let interfaceSoundEngine = InterfaceSoundEngine()' "$haptic_manager" ||
  ! grep -Fq 'private final class InterfaceSoundEngine' "$haptic_manager" ||
  ! grep -Fq 'spyclash.interface-sounds.recovered-after-noop-v1' "$haptic_manager"; then
  echo "The interface audio engine is not wired into HapticManager." >&2
  exit 1
fi
if grep -Fq 'func playSound(_ cue: SoundCue) {}' "$haptic_manager" ||
  grep -Fq 'UserDefaults.standard.set(false, forKey: Self.interfaceSoundsEnabledKey)' "$haptic_manager"; then
  echo "HapticManager contains a release-blocking audio no-op." >&2
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
if [ ! -f "$app/$bundle_executable" ] ||
  ! strings "$app/$bundle_executable" | grep -Fq 'com.spyclash.interface-audio' ||
  ! strings "$app/$bundle_executable" | grep -Fq 'spyclash.interface-sounds.recovered-after-noop-v1'; then
  echo "The compiled Release executable does not contain the recovered interface audio engine." >&2
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

echo "iOS Release bundle gate passed: $bundle_id $marketing_version ($build_number), 27 audible WAV files, privacy manifest exact, no .storekit."
