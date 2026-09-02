#!/bin/bash

set -euo pipefail
umask 077

PULLED_FUNCTION="${1:-}"
DEPLOY_FUNCTION="${2:-}"
EXPECTED_NAME="${3:-}"
EXPECTED_RUNTIME_COUNT="${4:-}"

fail() {
  echo "$1" >&2
  exit "${2:-65}"
}

assert_no_find_match() {
  local message=$1 match
  shift
  match="$(find "$@" -print -quit)" || \
    fail "Unable to inspect filesystem: $message" 77
  [[ -z "$match" ]] || fail "$message" 77
}

for command in cp dirname find jq mkdir mv mktemp rm tr wc; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command" 69
done

[[ -n "$PULLED_FUNCTION" && -n "$DEPLOY_FUNCTION" && \
  -n "$EXPECTED_NAME" && "$EXPECTED_RUNTIME_COUNT" =~ ^[1-9][0-9]*$ ]] || \
  fail "Usage: $0 <pulled-function> <deploy-function> <expected-name> <runtime-file-count>" 64
[[ -d "$PULLED_FUNCTION" && ! -L "$PULLED_FUNCTION" ]] || \
  fail "Pulled function is missing or unsafe." 77
[[ ! -e "$DEPLOY_FUNCTION" && ! -L "$DEPLOY_FUNCTION" ]] || \
  fail "Deploy function destination must not exist." 77

PULLED_CONFIG="$PULLED_FUNCTION/function.jsonc"
[[ -f "$PULLED_CONFIG" && ! -L "$PULLED_CONFIG" ]] || \
  fail "Pulled function config is missing or unsafe." 77
FUNCTION_NAME="$(jq -er '.name' "$PULLED_CONFIG")"
PULLED_ENTRY="$(jq -er '.entry' "$PULLED_CONFIG")"
[[ "$FUNCTION_NAME" == "$EXPECTED_NAME" ]] || \
  fail "Pulled function name mismatch." 77
[[ "$PULLED_ENTRY" == "base44/functions/$EXPECTED_NAME/entry.ts" ]] || \
  fail "Unsupported pulled function entry path." 77

PULLED_RUNTIME="$PULLED_FUNCTION/base44/functions/$EXPECTED_NAME"
[[ -d "$PULLED_RUNTIME" && ! -L "$PULLED_RUNTIME" && \
  -f "$PULLED_RUNTIME/entry.ts" ]] || \
  fail "Pulled function runtime is missing or unsafe." 77
assert_no_find_match "Nested directory in pulled function runtime." \
  "$PULLED_RUNTIME" -mindepth 1 -type d
assert_no_find_match "Symlink in pulled function runtime." \
  "$PULLED_RUNTIME" -type l
[[ "$(find "$PULLED_RUNTIME" -maxdepth 1 -type f | wc -l | tr -d ' ')" == \
  "$EXPECTED_RUNTIME_COUNT" ]] || fail "Pulled runtime file count mismatch." 77

DESTINATION_PARENT="$(dirname "$DEPLOY_FUNCTION")"
mkdir -p "$DESTINATION_PARENT"
WORK="$(mktemp -d "$DESTINATION_PARENT/.flatten-${EXPECTED_NAME}.XXXXXX")"
cleanup() {
  if [[ -d "$WORK" && ! -L "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$PULLED_RUNTIME/." "$WORK/"
jq '.entry = "entry.ts"' "$PULLED_CONFIG" > "$WORK/function.jsonc"

[[ "$(jq -er '.name' "$WORK/function.jsonc")" == "$EXPECTED_NAME" && \
  "$(jq -er '.entry' "$WORK/function.jsonc")" == "entry.ts" && \
  -f "$WORK/entry.ts" ]] || fail "Generated deploy function is invalid." 77
[[ "$(find "$WORK" -maxdepth 1 -type f | wc -l | tr -d ' ')" == \
  "$((EXPECTED_RUNTIME_COUNT + 1))" ]] || fail "Deploy file count mismatch." 77
assert_no_find_match "Nested directory in deploy function." \
  "$WORK" -mindepth 1 -type d
assert_no_find_match "Symlink in deploy function." "$WORK" -type l

mv "$WORK" "$DEPLOY_FUNCTION"
trap - EXIT HUP INT TERM
