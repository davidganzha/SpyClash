#!/bin/zsh

set -euo pipefail

root="$(cd "$(dirname "${0:A}")/.." && pwd)"
violations="$(
  {
    rg -n \
      'base44\.entities\.(GameRoom|WordPack)\.(create|update|delete|filter|list|subscribe)' \
      "$root/.web-reference/spyclash-web/src" || true
    rg -n \
      'base44\.entities\.(AiGenerationQuota|AiGenerationUsage|AppStoreAccount|Entitlement|BillingIdentityLifecycle|CommunityReport)\.' \
      "$root/.web-reference/spyclash-web/src" || true
    rg -n \
      'base44\.entities\.GameHistory\.(create|update|delete|list|subscribe)' \
      "$root/.web-reference/spyclash-web/src" || true
    rg -n -U \
      'base44\.entities\.GameHistory\.filter\(\s*\{\s*\}' \
      "$root/.web-reference/spyclash-web/src" || true
    rg -n \
      'loadAllOnlineGameHistory' \
      "$root/.web-reference/spyclash-web/src" || true
    rg -n -U \
      '(createEntity|updateEntity|deleteEntity|filterEntity)\(\s*"(GameRoom|WordPack)"' \
      "$root/SpyClash" || true
    rg -n -U \
      '(createEntity|updateEntity|deleteEntity|filterEntity)\(\s*"(AiGenerationQuota|AiGenerationUsage|AppStoreAccount|Entitlement|BillingIdentityLifecycle|CommunityReport)"' \
      "$root/SpyClash" || true
    rg -n -U \
      '(createEntity|updateEntity|deleteEntity)\(\s*"GameHistory"|filterEntity\(\s*"GameHistory"\s*,\s*query:\s*\[:\]' \
      "$root/SpyClash" || true
    rg -n \
      'allGameHistory\(' \
      "$root/SpyClash" || true
  }
)"

if [[ -n "$violations" ]]; then
  print -u2 -- "Sensitive entities still bypass their authenticated server actions:"
  print -u2 -- "$violations"
  exit 1
fi

print -- "Client entity boundary check passed."
