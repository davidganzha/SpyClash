#!/bin/sh
# Read-only regression gate. No Base44 login, invocation or deployment.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
sh scripts/sync-base44-billing-lifecycle.sh --check
python3 scripts/check-release-baseline.py
python3 -m unittest discover -s scripts/tests -p "check_release_baseline_test.py"
python3 - <<'PY'
from pathlib import Path
import re
yml = Path('project.yml').read_text()
project = Path('SpyClash.xcodeproj/project.pbxproj').read_text()
version = re.search(r'CURRENT_PROJECT_VERSION:\s*(\d+)', yml).group(1)
assert set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', project)) == {version}, 'Build versions are not synchronized'
PY
if command -v deno >/dev/null 2>&1; then
  deno test --allow-env --allow-net --allow-read \
    base44/functions/gameRoomAction \
    base44/functions/pushNotificationAction \
    base44/functions/communityAction \
    base44/functions/notificationAction \
    base44/functions/wordPackAction \
    base44/functions/generateWordPack/generation-write-lifecycle_test.ts \
    base44/functions/generateWordPack/generation-idempotency_test.ts \
    base44/functions/generateWordPack/quota_test.ts \
    base44/functions/stripe-entitlement-webhook/billing-identity-lifecycle_test.ts
else
  npx --yes deno@2.9.5 test --allow-env --allow-net --allow-read \
    base44/functions/gameRoomAction \
    base44/functions/pushNotificationAction \
    base44/functions/communityAction \
    base44/functions/notificationAction \
    base44/functions/wordPackAction \
    base44/functions/generateWordPack/generation-write-lifecycle_test.ts \
    base44/functions/generateWordPack/generation-idempotency_test.ts \
    base44/functions/generateWordPack/quota_test.ts \
    base44/functions/stripe-entitlement-webhook/billing-identity-lifecycle_test.ts
fi
