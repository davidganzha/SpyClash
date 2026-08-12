#!/bin/bash

set -euo pipefail

# Local-only App Store source capture. This script installs a Debug simulator
# build, launches the app's real SwiftUI preview fixtures, and captures the
# simulator framebuffer. It never calls App Store Connect or Base44.

BUNDLE_ID="com.spyclash.ios"
EXPECTED_DEVICE_NAME="iPhone 17 Pro Max"
EXPECTED_WIDTH=1320
EXPECTED_HEIGHT=2868
MIN_FULL_CAPTURE_BUILD=15

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
FLATTEN_SCRIPT="$SCRIPT_DIR/flatten-app-store-screenshots.swift"

ALL_SCREENS=(
    "home"
    "online-lobby-qr"
    "role-reveal"
    "active-round"
    "local-pass-and-play"
    "word-packs-ai"
    "community-attention"
)

APP_PATH=""
LOCALE_INPUT=""
OUTPUT_ROOT=""
DEVICE_UDID=""
WAIT_SECONDS="3.0"
INSTALL_APP=1
OVERWRITE=0
DRY_RUN=0
LIST_ONLY=0
REQUESTED_SCREENS=()

usage() {
    cat <<'USAGE'
Usage:
  scripts/capture-app-store-source-screenshots.sh \
    --app /absolute/path/SpyClash.app \
    --locale en|ru|es|uk \
    --output /absolute/path/to/source-captures \
    [--screen NAME[,NAME...]] [--device UDID] [--wait SECONDS]
    [--skip-install] [--overwrite] [--dry-run]

The output is written under a normalized locale directory:
  en -> en-US, ru -> ru, es -> es-ES, uk -> uk-UA

By default all seven fixtures are captured. Before CFBundleVersion 15 the
script deliberately permits at most two screens, so build 14 can only be used
for a smoke test.

Options:
  --app PATH          Debug-iphonesimulator SpyClash.app artifact.
  --locale LOCALE     en/en-US, ru/ru-RU, es/es-ES, or uk/uk-UA.
  --output DIR        Root output directory. Existing files are preserved.
  --screen NAME       Capture one or more comma-separated fixture names.
                      Repeat the option to add more fixtures.
  --device UDID       Booted iPhone 17 Pro Max. Auto-detected when omitted.
  --wait SECONDS      Base settling delay after launch (default: 3.0).
  --skip-install      Use the already installed com.spyclash.ios app.
  --overwrite         Replace only the exact requested output PNG files.
  --dry-run           Validate inputs and print the planned capture only.
  --list-screens      Print fixture names and exit.
  -h, --help          Show this help.
USAGE
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

list_screens() {
    cat <<'SCREENS'
home                         Home mission entry
online-lobby-qr              Online waiting room with the real room QR sheet
role-reveal                  Online role-card reveal gate (card initially concealed)
active-round                 Online active round with deterministic preview room data
local-pass-and-play          Local pass-and-play active round
word-packs-ai                Word packs and AI theme-generation surface
community-attention          Community invitations and friend-request fixture
SCREENS
}

require_value() {
    local option=$1
    local value=${2-}
    [[ -n "$value" ]] || die "$option requires a value"
}

append_screens() {
    local value=$1
    local pieces=()
    local piece

    IFS=',' read -r -a pieces <<< "$value"
    for piece in "${pieces[@]}"; do
        [[ -n "$piece" ]] || die "empty screen name in --screen $value"
        REQUESTED_SCREENS+=("$piece")
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            require_value "$1" "${2-}"
            APP_PATH=$2
            shift 2
            ;;
        --locale)
            require_value "$1" "${2-}"
            LOCALE_INPUT=$2
            shift 2
            ;;
        --output)
            require_value "$1" "${2-}"
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --screen)
            require_value "$1" "${2-}"
            append_screens "$2"
            shift 2
            ;;
        --device)
            require_value "$1" "${2-}"
            DEVICE_UDID=$2
            shift 2
            ;;
        --wait)
            require_value "$1" "${2-}"
            WAIT_SECONDS=$2
            shift 2
            ;;
        --skip-install)
            INSTALL_APP=0
            shift
            ;;
        --overwrite)
            OVERWRITE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --list-screens)
            LIST_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [[ $LIST_ONLY -eq 1 ]]; then
    list_screens
    exit 0
fi

[[ -n "$APP_PATH" ]] || die "--app is required"
[[ -n "$LOCALE_INPUT" ]] || die "--locale is required"
[[ -n "$OUTPUT_ROOT" ]] || die "--output is required"
[[ "$WAIT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--wait must be a non-negative number"

case "$LOCALE_INPUT" in
    en|en-US|en_US)
        APP_LANGUAGE="en"
        APPLE_LANGUAGE="en"
        APPLE_LOCALE="en_US"
        OUTPUT_LOCALE="en-US"
        ;;
    ru|ru-RU|ru_RU)
        APP_LANGUAGE="ru"
        APPLE_LANGUAGE="ru"
        APPLE_LOCALE="ru_RU"
        OUTPUT_LOCALE="ru"
        ;;
    es|es-ES|es_ES)
        APP_LANGUAGE="es"
        APPLE_LANGUAGE="es"
        APPLE_LOCALE="es_ES"
        OUTPUT_LOCALE="es-ES"
        ;;
    uk|uk-UA|uk_UA)
        APP_LANGUAGE="uk"
        APPLE_LANGUAGE="uk"
        APPLE_LOCALE="uk_UA"
        OUTPUT_LOCALE="uk-UA"
        ;;
    *)
        die "unsupported locale '$LOCALE_INPUT'; use en, ru, es, or uk"
        ;;
esac

if [[ ${#REQUESTED_SCREENS[@]} -eq 0 ]]; then
    REQUESTED_SCREENS=("${ALL_SCREENS[@]}")
fi

is_known_screen() {
    local candidate=$1
    local known
    for known in "${ALL_SCREENS[@]}"; do
        [[ "$candidate" == "$known" ]] && return 0
    done
    return 1
}

validate_requested_screens() {
    local index
    local other
    local screen

    for ((index = 0; index < ${#REQUESTED_SCREENS[@]}; index++)); do
        screen=${REQUESTED_SCREENS[$index]}
        is_known_screen "$screen" || die "unknown screen '$screen' (use --list-screens)"
        for ((other = 0; other < index; other++)); do
            [[ "$screen" != "${REQUESTED_SCREENS[$other]}" ]] || die "screen '$screen' was requested more than once"
        done
    done
}

validate_requested_screens

[[ -d "$APP_PATH" ]] || die "app bundle does not exist: $APP_PATH"
[[ -f "$APP_PATH/Info.plist" ]] || die "missing Info.plist in app bundle: $APP_PATH"
[[ -f "$FLATTEN_SCRIPT" ]] || die "missing RGB flattener: $FLATTEN_SCRIPT"

APP_PATH=$(CDPATH= cd -- "$APP_PATH" && pwd -P)

APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null) \
    || die "cannot read CFBundleIdentifier from $APP_PATH"
[[ "$APP_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "expected $BUNDLE_ID, found $APP_BUNDLE_ID"

APP_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null) \
    || die "cannot read CFBundleExecutable from $APP_PATH"
[[ -f "$APP_PATH/$APP_EXECUTABLE" ]] || die "missing app executable: $APP_PATH/$APP_EXECUTABLE"

PREVIEW_PAYLOAD="$APP_PATH/$APP_EXECUTABLE"
if [[ -f "$APP_PATH/${APP_EXECUTABLE}.debug.dylib" ]]; then
    PREVIEW_PAYLOAD="$APP_PATH/${APP_EXECUTABLE}.debug.dylib"
fi

if ! LC_ALL=C /usr/bin/grep -a -F -q -- '--spyclash-ui-preview' "$PREVIEW_PAYLOAD"; then
    die "the app does not contain Debug preview fixtures; pass a Debug-iphonesimulator artifact"
fi

APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist" 2>/dev/null) \
    || die "cannot read CFBundleVersion from $APP_PATH"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null) \
    || die "cannot read CFBundleShortVersionString from $APP_PATH"

if [[ ${#REQUESTED_SCREENS[@]} -gt 2 ]]; then
    [[ "$APP_BUILD" =~ ^[0-9]+$ ]] || die "cannot verify build-15 gate from CFBundleVersion '$APP_BUILD'"
    (( APP_BUILD >= MIN_FULL_CAPTURE_BUILD )) \
        || die "full capture is gated until build $MIN_FULL_CAPTURE_BUILD; build $APP_BUILD may capture at most two smoke-test screens"
fi

resolve_device() {
    local requested=$1
    xcrun simctl list devices booted --json | /usr/bin/python3 -c '
import json
import sys

requested = sys.argv[1]
expected_name = sys.argv[2]
payload = json.load(sys.stdin)
devices = [
    device
    for runtime_devices in payload.get("devices", {}).values()
    for device in runtime_devices
    if device.get("state") == "Booted"
]

if requested:
    devices = [device for device in devices if device.get("udid") == requested]
else:
    devices = [device for device in devices if device.get("name") == expected_name]

if len(devices) != 1:
    sys.exit(2)

device = devices[0]
print("{}\t{}".format(device.get("name", ""), device.get("udid", "")))
' "$requested" "$EXPECTED_DEVICE_NAME"
}

DEVICE_INFO=$(resolve_device "$DEVICE_UDID") \
    || die "boot exactly one $EXPECTED_DEVICE_NAME simulator, or pass its booted UDID with --device"
DEVICE_NAME=${DEVICE_INFO%%$'\t'*}
RESOLVED_UDID=${DEVICE_INFO#*$'\t'}
[[ "$DEVICE_NAME" == "$EXPECTED_DEVICE_NAME" ]] \
    || die "device $RESOLVED_UDID is '$DEVICE_NAME'; $EXPECTED_DEVICE_NAME is required for ${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}"
DEVICE_UDID=$RESOLVED_UDID

mkdir -p -- "$OUTPUT_ROOT"
OUTPUT_ROOT=$(CDPATH= cd -- "$OUTPUT_ROOT" && pwd -P)
LOCALE_OUTPUT="$OUTPUT_ROOT/$OUTPUT_LOCALE"
mkdir -p -- "$LOCALE_OUTPUT"

fixture_configuration() {
    local screen=$1
    FIXTURE_ARGS=()
    FIXTURE_EXTRA_WAIT="0"

    case "$screen" in
        home)
            FIXTURE_FILENAME="01-home.png"
            FIXTURE_ARGS=("--spyclash-preview-tab=home")
            # The first localized launch must warm both the custom wordmark
            # font and SF Symbols before simctl snapshots the framebuffer.
            FIXTURE_EXTRA_WAIT="12.0"
            ;;
        online-lobby-qr)
            FIXTURE_FILENAME="02-online-lobby-qr.png"
            FIXTURE_ARGS=(
                "--spyclash-preview-tab=game"
                "--spyclash-preview-room=waiting"
                "--spyclash-preview-sheet=roomQR"
            )
            FIXTURE_EXTRA_WAIT="2.5"
            ;;
        role-reveal)
            FIXTURE_FILENAME="03-role-reveal.png"
            FIXTURE_ARGS=(
                "--spyclash-preview-tab=game"
                "--spyclash-preview-room=cards"
                "--spyclash-preview-reveal-role"
            )
            FIXTURE_EXTRA_WAIT="2.5"
            ;;
        active-round)
            FIXTURE_FILENAME="04-active-round.png"
            FIXTURE_ARGS=(
                "--spyclash-preview-tab=game"
                "--spyclash-preview-room=playing"
            )
            FIXTURE_EXTRA_WAIT="35.0"
            ;;
        local-pass-and-play)
            FIXTURE_FILENAME="05-local-pass-and-play.png"
            FIXTURE_ARGS=(
                "--spyclash-preview-tab=local"
                "--spyclash-preview-local-mode=questions"
                "--spyclash-preview-local-phase=playing"
                "--spyclash-preview-local-duration-seconds=422"
            )
            FIXTURE_EXTRA_WAIT="0.8"
            ;;
        word-packs-ai)
            FIXTURE_FILENAME="06-word-packs-ai.png"
            FIXTURE_ARGS=("--spyclash-preview-tab=packs")
            FIXTURE_EXTRA_WAIT="17.0"
            ;;
        community-attention)
            FIXTURE_FILENAME="07-community-attention.png"
            FIXTURE_ARGS=("--spyclash-preview-sheet=community")
            # The Community route mounts after the shell and its wordmark must
            # finish the same warm-up path as Home before capture.
            FIXTURE_EXTRA_WAIT="35.0"
            ;;
        *)
            die "internal fixture mapping is missing for '$screen'"
            ;;
    esac
}

decimal_sum() {
    /usr/bin/awk -v left="$1" -v right="$2" 'BEGIN { printf "%.2f", left + right }'
}

validate_png() {
    local path=$1
    local properties
    local width
    local height
    local alpha
    local format

    properties=$(/usr/bin/sips \
        -g pixelWidth \
        -g pixelHeight \
        -g hasAlpha \
        -g format \
        "$path" 2>/dev/null) || die "cannot inspect captured image: $path"
    width=$(printf '%s\n' "$properties" | /usr/bin/awk '/pixelWidth:/ { print $2; exit }')
    height=$(printf '%s\n' "$properties" | /usr/bin/awk '/pixelHeight:/ { print $2; exit }')
    alpha=$(printf '%s\n' "$properties" | /usr/bin/awk '/hasAlpha:/ { print $2; exit }')
    format=$(printf '%s\n' "$properties" | /usr/bin/awk '/format:/ { print $2; exit }')

    [[ "$width" == "$EXPECTED_WIDTH" ]] \
        || die "$path is ${width}x${height}; expected ${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}"
    [[ "$height" == "$EXPECTED_HEIGHT" ]] \
        || die "$path is ${width}x${height}; expected ${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}"
    [[ "$alpha" == "no" ]] || die "$path still has an alpha channel"
    [[ "$format" == "png" ]] || die "$path is '$format', not PNG"
}

printf 'SpyClash App Store source capture\n'
printf '  artifact: %s %s (%s)\n' "$BUNDLE_ID" "$APP_VERSION" "$APP_BUILD"
printf '  device:   %s (%s)\n' "$DEVICE_NAME" "$DEVICE_UDID"
printf '  locale:   %s -> %s\n' "$LOCALE_INPUT" "$LOCALE_OUTPUT"
printf '  screens:  %s\n' "${REQUESTED_SCREENS[*]}"

if [[ $DRY_RUN -eq 1 ]]; then
    for screen in "${REQUESTED_SCREENS[@]}"; do
        fixture_configuration "$screen"
        printf '  plan:     %s -> %s/%s\n' "$screen" "$LOCALE_OUTPUT" "$FIXTURE_FILENAME"
    done
    exit 0
fi

if [[ $OVERWRITE -ne 1 ]]; then
    for screen in "${REQUESTED_SCREENS[@]}"; do
        fixture_configuration "$screen"
        [[ ! -e "$LOCALE_OUTPUT/$FIXTURE_FILENAME" ]] \
            || die "refusing to replace existing file: $LOCALE_OUTPUT/$FIXTURE_FILENAME (pass --overwrite for this exact output set)"
    done
fi

if [[ $INSTALL_APP -eq 1 ]]; then
    printf 'Installing Debug artifact on the local simulator...\n'
    xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
else
    INSTALLED_CONTAINER=$(xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" app 2>/dev/null) \
        || die "$BUNDLE_ID is not installed on $DEVICE_UDID"
    INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_CONTAINER/Info.plist" 2>/dev/null) \
        || die "cannot inspect the installed app"
    [[ "$INSTALLED_BUILD" == "$APP_BUILD" ]] \
        || die "--skip-install artifact is build $APP_BUILD, but the installed app is build $INSTALLED_BUILD"

    INSTALLED_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INSTALLED_CONTAINER/Info.plist" 2>/dev/null) \
        || die "cannot inspect the installed app executable"
    INSTALLED_PREVIEW_PAYLOAD="$INSTALLED_CONTAINER/$INSTALLED_EXECUTABLE"
    if [[ -f "$INSTALLED_CONTAINER/${INSTALLED_EXECUTABLE}.debug.dylib" ]]; then
        INSTALLED_PREVIEW_PAYLOAD="$INSTALLED_CONTAINER/${INSTALLED_EXECUTABLE}.debug.dylib"
    fi
    if ! LC_ALL=C /usr/bin/grep -a -F -q -- '--spyclash-ui-preview' "$INSTALLED_PREVIEW_PAYLOAD"; then
        die "--skip-install found a non-Debug app; install the provided Debug artifact first"
    fi
fi

ORIGINAL_APPEARANCE=$(xcrun simctl ui "$DEVICE_UDID" appearance 2>/dev/null || true)
restore_simulator_presentation() {
    xcrun simctl status_bar "$DEVICE_UDID" clear >/dev/null 2>&1 || true
    case "$ORIGINAL_APPEARANCE" in
        light|dark)
            xcrun simctl ui "$DEVICE_UDID" appearance "$ORIGINAL_APPEARANCE" >/dev/null 2>&1 || true
            ;;
    esac
}
trap restore_simulator_presentation EXIT HUP INT TERM

xcrun simctl ui "$DEVICE_UDID" appearance dark
xcrun simctl status_bar "$DEVICE_UDID" override \
    --time 09:41 \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --operatorName '' \
    --batteryState charged \
    --batteryLevel 100

CAPTURED=0
for screen in "${REQUESTED_SCREENS[@]}"; do
    fixture_configuration "$screen"
    FINAL_PATH="$LOCALE_OUTPUT/$FIXTURE_FILENAME"

    SETTLE_SECONDS=$(decimal_sum "$WAIT_SECONDS" "$FIXTURE_EXTRA_WAIT")
    printf 'Launching %s (%s), then waiting %ss...\n' "$screen" "$APP_LANGUAGE" "$SETTLE_SECONDS"

    SIMCTL_CHILD_AppleLanguages="($APPLE_LANGUAGE)" \
    SIMCTL_CHILD_AppleLocale="$APPLE_LOCALE" \
        xcrun simctl launch \
            --terminate-running-process \
            "$DEVICE_UDID" \
            "$BUNDLE_ID" \
            "--spyclash-ui-preview" \
            "--spyclash-preview-lang=$APP_LANGUAGE" \
            -AppleLanguages "($APPLE_LANGUAGE)" \
            -AppleLocale "$APPLE_LOCALE" \
            "${FIXTURE_ARGS[@]}"

    /bin/sleep "$SETTLE_SECONDS"

    # `simctl io screenshot` can be denied direct writes inside protected
    # user folders even when this script may create files there. Capture in
    # /tmp first, then move the validated RGB result into AppStoreAssets.
    TEMP_CAPTURE=$(mktemp "/tmp/spyclash-${FIXTURE_FILENAME%.png}.raw.XXXXXX") \
        || die "cannot create a temporary capture in /tmp"
    xcrun simctl io "$DEVICE_UDID" screenshot \
        --type=png \
        --mask=ignored \
        "$TEMP_CAPTURE"

    # simctl emits RGBA PNGs even with an opaque framebuffer. Re-encode the
    # exact captured pixels against black so App Store source files are RGB.
    xcrun swift "$FLATTEN_SCRIPT" "$TEMP_CAPTURE"
    validate_png "$TEMP_CAPTURE"

    if [[ $OVERWRITE -eq 1 ]]; then
        /bin/mv -f -- "$TEMP_CAPTURE" "$FINAL_PATH"
    else
        /bin/mv -- "$TEMP_CAPTURE" "$FINAL_PATH"
    fi
    validate_png "$FINAL_PATH"
    CAPTURED=$((CAPTURED + 1))
    printf 'Captured %s\n' "$FINAL_PATH"
done

printf 'Done: %d RGB PNG source screenshot(s), each %dx%d.\n' \
    "$CAPTURED" "$EXPECTED_WIDTH" "$EXPECTED_HEIGHT"
