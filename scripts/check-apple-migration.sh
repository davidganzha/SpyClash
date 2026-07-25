#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

TEAM_ID=3Z64QKNL54
BUNDLE_ID=com.spyclash.ios
APPLE_APP_ID=6793534085

require_text() {
  file=$1
  expected=$2
  if ! grep -Fq "$expected" "$ROOT/$file"; then
    echo "Apple migration mismatch: $file does not contain $expected" >&2
    exit 78
  fi
}

require_text project.yml "PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID"
require_text project.yml "DEVELOPMENT_TEAM: $TEAM_ID"
require_text SpyClash.xcodeproj/project.pbxproj "PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;"
require_text SpyClash.xcodeproj/project.pbxproj "DEVELOPMENT_TEAM = $TEAM_ID;"
require_text SpyClash/Services/KeychainStore.swift "$BUNDLE_ID"
require_text SpyClash/Services/KeychainStore.swift \
  'private static let legacyService = "com.spyclash.app"'
require_text SpyClash/Services/KeychainStore.swift \
  'readToken(service: legacyService)'
require_text SpyClash/Services/KeychainStore.swift \
  'deleteToken(service: legacyService)'
require_text base44/functions/appleAuthBroker/main.ts \
  "EXPECTED_APPLE_NATIVE_CLIENT_ID = \"$BUNDLE_ID\""
require_text base44/functions/appleAuthBroker/main.ts \
  'const APP_ID = "69a0e57fa939f578082f8091"'
require_text base44/functions/app-store-entitlement/apple-entitlement.ts \
  "SPYCLASH_IOS_BUNDLE_ID = \"$BUNDLE_ID\""
require_text base44/functions/app-store-entitlement/apple-entitlement.ts \
  "SPYCLASH_APPLE_APP_ID = $APPLE_APP_ID"
if [ -f "$ROOT/APP_STORE_SUBMISSION.md" ]; then
  require_text APP_STORE_SUBMISSION.md "App Store Connect Apple ID: \`$APPLE_APP_ID\`"
fi

if grep -R -F -n \
  --exclude='*.xcuserstate' \
  --exclude='*_test.ts' \
  --exclude='check-apple-migration.sh' \
  --exclude='KeychainStore.swift' \
  --exclude-dir='.git' \
  --exclude-dir='node_modules' \
  --exclude-dir='.build' \
  'com.spyclash.app' \
  "$ROOT/project.yml" \
  "$ROOT/SpyClash.xcodeproj" \
  "$ROOT/SpyClash" \
  "$ROOT/StoreKit" \
  "$ROOT/base44/functions/appleAuthBroker" \
  "$ROOT/base44/functions/app-store-entitlement"; then
  echo "Apple migration mismatch: legacy bundle identity remains." >&2
  exit 78
fi

if ! jq empty "$ROOT/StoreKit/SpyClash.storekit"; then
  echo "StoreKit configuration is not valid JSON." >&2
  exit 65
fi

echo "Apple migration preflight passed."
echo "Expected Base44 values:"
echo "  APPLE_NATIVE_CLIENT_ID=$BUNDLE_ID"
echo "  SPYCLASH_APP_ID=69a0e57fa939f578082f8091"
