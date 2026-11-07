# Rewarded generation callback gateway

This is a local activation candidate. Adding these files does not deploy a function,
enable a quota, configure AdMob, or grant any real reward.

One owned AdMob rewarded unit can use the callback URL:

`https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv`

Only this function must have `verify_jwt = false`. Keep the existing
`app-services` function's platform JWT check enabled. Google sends a signed query,
not a Supabase user token; the platform JWT check runs before the function handler.
See [Supabase authorization headers](https://supabase.com/docs/guides/functions/auth-headers)
and [Google rewarded SSV](https://developers.google.com/admob/ios/ssv).

The gateway checks Google's ECDSA signature, then accepts only server-issued
`UUID.native.64hex` or `UUID.legacy.64hex` custom data and reward `1 generation`.
Native callbacks reach the existing native handler, which independently verifies
the signature and commits the matching issued attempt in its locked transaction.
Legacy callbacks preserve the signed query's order and encoding and go only to
`https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/generationRewardAction`.
Base44 verifies the signature again and applies its own idempotent ledger grant.
The gateway does not own a balance, forward user credentials, follow redirects,
or log callback queries. A legacy response must be HTTP success and bounded JSON
with `success: true`; failures remain retryable. The duplicate result is successful.

Callbacks remain eligible when new ad offers are disabled. Do not remove the
gateway or ledger while issued rewards can still arrive. New namespaced tokens
must be issued by both backends before using this unified URL; the gateway does
not guess a wallet for the old unnamespaced format. Existing direct Base44/native
handlers retain their original issued-token validation.

## Activation prerequisites

- Supabase project `bbkfsgnordtdiblgdzkg`: additive migration
  `20261105224817_rewarded_generation_credits.sql`.
- A reviewed `app-services` package based on the live v17 bundle plus only the
  reward changes; do not deploy unrelated local achievements, loyalty, invitation,
  push, or game-rule changes as part of this activation.
- The new `rewarded-generation-ssv` function and its pinned imports, with the
  per-function public webhook setting. Its existing `SUPABASE_URL` and
  `SUPABASE_DB_URL` environment must point to the canonical project.
- Base44 `GenerationReward` schema and `generationRewardAction`, updated
  `generateWordPack` reward enforcement, and namespaced legacy issuance.
- The same owned unit in `ADMOB_REWARDED_AD_UNIT_ID` on both backends; enable
  `SPYCLASH_REWARDED_GENERATION_ENABLED` only as a separately approved rollout.
- AdMob reward `1 generation`, this callback URL, and the matching owned IDs in
  an explicitly enabled release build. Google's sample unit cannot prove SSV.

Production readback on 2026-11-07 found app-services v17 with JWT verification on,
no reward modules/schema migration/table/charge-source column, and neither reward
configuration name present. A fresh readback is required immediately before any
approved deployment. No production activation is performed by this candidate.

The first proposed production step is additive publication with both feature
flags absent/false. Turning the global flag on would also impose the new quota
on already installed build 218, whose advertising UI is disabled. Do not enable
that global flag merely to test SSV. A reviewed test-account allowlist or a fully
separate test backend is still required for a real end-to-end experiment. This
gateway's legacy branch is pinned to production Base44: a native-only isolated
test does not establish readiness of the legacy route. No test allowlist or
version-aware rollout is implemented by this change.

## Offline checks

Run `deno test --config supabase/functions/rewarded-generation-ssv/deno.json
supabase/functions/rewarded-generation-ssv/handler_test.ts` from
`experiments/supabase-game-core`. The tests use synthetic signing keys and injected
fetch responses; no provider or production endpoint is contacted.

The existing `tests/game-center/rewarded-generation-integration.ts` suite accepts
only loopback PostgreSQL via `REWARDED_TEST_DATABASE_URL`, creates its own random
database, and drops it in cleanup. It verifies namespaced issuance and the public
gateway along with concurrent grants/spending, exact-once refunds, late callbacks,
unknown provider outcomes, LIMITLESS, and deletion. The public gateway's duplicate
acknowledgment relies on those authoritative ledger checks, not on local memory.
