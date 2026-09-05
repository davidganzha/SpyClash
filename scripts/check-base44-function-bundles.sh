#!/bin/zsh

set -euo pipefail

root="$(cd "$(dirname "${0:A}")/.." && pwd)"
functions_root="$root/base44/functions"

# Base44 deploys each function directory as an isolated bundle. A relative
# import that climbs above that directory may pass local Deno checks while the
# deployed function fails because the sibling source was never uploaded.
# Cross-function regression tests run locally and are excluded from deployment.
violations="$(
  rg -n --glob '*.ts' --glob '*.js' --glob '!*_test.ts' \
    "from[[:space:]]+['\"]\\.\\./|import\\(['\"]\\.\\./" \
    "$functions_root" || true
)"

if [[ -n "$violations" ]]; then
  print -u2 -- "Cross-function relative imports are not deployable by Base44:"
  print -u2 -- "$violations"
  exit 1
fi

print -- "Base44 function bundle isolation check passed."
