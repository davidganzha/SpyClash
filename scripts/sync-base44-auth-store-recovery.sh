#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/base44/functions/appleAuthBroker/auth-store-recovery.ts"
TARGET="$ROOT/base44/functions/autoRegisterUser/auth-store-recovery.ts"
if [ "${1:-}" = "--check" ]; then
  cmp -s "$SOURCE" "$TARGET" || {
    echo "Authentication store recovery helper is stale: $TARGET" >&2
    exit 1
  }
else
  cp "$SOURCE" "$TARGET"
fi
