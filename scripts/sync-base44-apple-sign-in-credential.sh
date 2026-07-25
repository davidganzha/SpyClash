#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/base44/functions/appleAuthBroker/apple-sign-in-credential.ts"
TARGETS="
$ROOT/base44/functions/autoRegisterUser/apple-sign-in-credential.ts
$ROOT/base44/functions/deleteAccount/apple-sign-in-credential.ts
"

if [ "${1:-}" = "--check" ]; then
  for target in $TARGETS; do
    if ! cmp -s "$SOURCE" "$target"; then
      echo "Apple Sign in credential helper is stale: $target" >&2
      exit 1
    fi
  done
  exit 0
fi

for target in $TARGETS; do
  cp "$SOURCE" "$target"
done
