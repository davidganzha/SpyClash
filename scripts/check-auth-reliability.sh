#!/bin/sh
# Offline runtime checks; no provider accounts, secrets, or hosted writes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
sh scripts/sync-base44-apple-sign-in-credential.sh --check
sh scripts/sync-base44-auth-store-recovery.sh --check
run_deno() {
  if command -v deno >/dev/null 2>&1; then deno "$@"
  else npx --yes deno@2.9.5 "$@"
  fi
}
# The real SDK's debug dependency enumerates process.env during module loading;
# handler fixtures supply their own synthetic configuration and deny networking.
run_deno test --no-lock --no-config --deny-net --allow-env --no-prompt \
  --allow-read=base44/functions/appleAuthBroker \
  base44/functions/appleAuthBroker
run_deno test --no-lock --deny-net --deny-env --no-prompt \
  --config experiments/supabase-game-core/tests/auto-register-v2/deno.json \
  experiments/supabase-game-core/tests/auto-register-v2/contract_test.ts
