#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_APP_ID=69a0e57fa939f578082f8091
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/base44/.app.jsonc" | head -n 1)
[ "$APP_ID" = "$EXPECTED_APP_ID" ] || {
  echo "Repository app id is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
  exit 77
}
if [ "${BASE44_APP_ID+x}" = x ] && [ "$BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
  exit 77
fi

LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/spyclash-release-secrets.XXXXXX")
NAMES_FILE=$(mktemp "${TMPDIR:-/tmp}/spyclash-release-secret-names.XXXXXX")
cleanup() {
  rm -f "$LIST_FILE" "$NAMES_FILE"
}
trap cleanup EXIT HUP INT TERM

if ! env -u BASE44_APP_ID npx --yes base44@0.1.4 \
  --app-id "$APP_ID" secrets list > "$LIST_FILE" 2>&1; then
  echo "Unable to verify Base44 release secret names." >&2
  exit 70
fi

# The CLI prints status text around the names. Retain only identifier-shaped
# lines and never print, request, or persist any secret value.
sed -n '/^[A-Z][A-Z0-9_]*$/p' "$LIST_FILE" | LC_ALL=C sort -u > "$NAMES_FILE"

missing=0
for name in \
  SPYCLASH_APP_ID \
  SPYCLASH_PSEUDONYM_KEY \
  APPLE_KEY_ID \
  APPLE_NATIVE_CLIENT_ID \
  APPLE_PRIVATE_KEY_P8_B64 \
  APPLE_TEAM_ID \
  APPLE_WEB_CLIENT_ID \
  APPLE_IAP_APPLE_ID \
  APPLE_IAP_BUNDLE_ID \
  APPLE_IAP_ISSUER_ID \
  APPLE_IAP_KEY_ID \
  APPLE_IAP_PRODUCT_ID \
  APNS_KEY_ID \
  APNS_PRIVATE_KEY \
  APNS_TEAM_ID \
  APNS_TOPIC \
  PUSH_INTERNAL_SECRET \
  PUSH_TOKEN_ENCRYPTION_KEY \
  STRIPE_LIMITLESS_PRICE_ID \
  STRIPE_SECRET_KEY \
  STRIPE_WEBHOOK_SECRET
do
  if ! grep -qx "$name" "$NAMES_FILE"; then
    echo "Missing required Base44 release secret: $name" >&2
    missing=1
  fi
done

# Apple subscription reconciliation accepts either supported private-key
# encoding, but ambiguous duplicate configuration is unsafe.
iap_key_count=0
for name in APPLE_IAP_PRIVATE_KEY_P8_B64 APPLE_IAP_PRIVATE_KEY_P8; do
  if grep -qx "$name" "$NAMES_FILE"; then
    iap_key_count=$((iap_key_count + 1))
  fi
done
if [ "$iap_key_count" -ne 1 ]; then
  echo "Exactly one Apple IAP private-key secret must be configured." >&2
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo "Base44 release secret preflight failed; no secret values were read." >&2
  exit 78
fi

echo "Base44 release secret-name preflight passed."
