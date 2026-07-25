#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/base44/functions/stripe-entitlement-webhook/billing-identity-lifecycle.ts"
PERSISTENCE_SOURCE="$ROOT/base44/functions/stripe-entitlement-webhook/stripe-entitlement-persistence.ts"
PERSISTENCE_TARGET="$ROOT/base44/functions/checkSubscription/stripe-entitlement-persistence.ts"
if [ "${1:-}" = "--check" ]; then
  for target in \
    "$ROOT/base44/functions/checkSubscription/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/createCheckout/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/appleAuthBroker/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/autoRegisterUser/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/deleteAccount/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/communityAction/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/gameRoomAction/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/pushNotificationAction/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/generateWordPack/billing-identity-lifecycle.ts" \
    "$ROOT/base44/functions/wordPackAction/billing-identity-lifecycle.ts"
  do
    if ! cmp -s "$SOURCE" "$target"; then
      echo "Billing lifecycle copy is stale: $target" >&2
      exit 1
    fi
  done
  if ! cmp -s "$PERSISTENCE_SOURCE" "$PERSISTENCE_TARGET"; then
    echo "Stripe persistence copy is stale: $PERSISTENCE_TARGET" >&2
    exit 1
  fi
  exit 0
fi

for target in \
  "$ROOT/base44/functions/checkSubscription/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/createCheckout/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/appleAuthBroker/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/autoRegisterUser/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/deleteAccount/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/communityAction/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/gameRoomAction/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/pushNotificationAction/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/generateWordPack/billing-identity-lifecycle.ts" \
  "$ROOT/base44/functions/wordPackAction/billing-identity-lifecycle.ts"
do
  cp "$SOURCE" "$target"
done
cp "$PERSISTENCE_SOURCE" "$PERSISTENCE_TARGET"
