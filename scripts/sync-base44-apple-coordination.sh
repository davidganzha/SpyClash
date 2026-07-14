#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BINDING_SOURCE="$ROOT/base44/functions/app-store-entitlement/apple-account-binding.ts"
BINDING_TARGET="$ROOT/base44/functions/deleteAccount/apple-account-binding.ts"
DELETION_SOURCE="$ROOT/base44/functions/deleteAccount/apple-account-deletion-lease.ts"
DELETION_TARGET="$ROOT/base44/functions/app-store-entitlement/apple-account-deletion-lease.ts"

if [ "${1:-}" = "--check" ]; then
  if ! cmp -s "$BINDING_SOURCE" "$BINDING_TARGET"; then
    echo "Apple binding copy is stale: $BINDING_TARGET" >&2
    exit 1
  fi
  if ! cmp -s "$DELETION_SOURCE" "$DELETION_TARGET"; then
    echo "Apple deletion coordination copy is stale: $DELETION_TARGET" >&2
    exit 1
  fi
  exit 0
fi

cp "$BINDING_SOURCE" "$BINDING_TARGET"
cp "$DELETION_SOURCE" "$DELETION_TARGET"
