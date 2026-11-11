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

For reward callbacks, the gateway checks Google's ECDSA signature, then accepts only server-issued
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

## AdMob dashboard verification without a reward

AdMob requires **Verify URL**, then **Use verified URL**, before the callback can
be saved. Its optional User ID and Custom data fields are for that test request.
See [AdMob callback setup](https://support.google.com/admob/answer/9603226?hl=en).

Use these exact reserved values in the dashboard only:

- User ID: `spyclash_admob_setup_probe`
- Custom data: `spyclash_setup_probe_v1`

After the normal Google signature check, the gateway accepts this pair only with
the synthetic signed ad unit `1234567890`, reward amount `1`, and item `generation`.
This exact payload was observed in the AdMob console's signed **Verify URL** request
on 2026-11-07; it is not a documented Google compatibility guarantee. A valid owned
`ADMOB_REWARDED_AD_UNIT_ID` must still be configured. Both reserved values must
match together; unsigned or tampered requests still fail. Missing or sample-unit
configuration returns 503; a mismatched signed probe returns 400. Using the actual
owned unit, including its numeric suffix, with these reserved markers also fails.
The successful response is HTTP 200 with
`{"received":true,"setup_probe":true,"reward_granted":false}` and `Cache-Control: no-store`.
It returns before either ledger handler or any Base44 forwarding, performs no
database writes, and grants nothing even if repeated. The only external lookup is
the existing Google public-key verification. New-offer flags remain absent/false;
the probe does not enable offers or relax any real issued-attempt checks.

These marker strings are SpyClash's contract, not Google-defined test constants.
Google's documentation does not specify fixed dashboard test ad-unit/reward
values. If its test payload changes, investigate the signed evidence and review
this narrow contract rather than loosening real reward validation. Confirm the
strict live probe result before claiming URL verification;
do not use a real issued reward attempt as the dashboard probe. A successful
setup probe proves signed callback delivery, not a completed ad or reward credit.

## Historical AdMob activation prerequisites (7 November)

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

Pre-publication readback on 2026-11-07 found app-services v17 with JWT verification on,
no reward modules/schema migration/table/charge-source column, and neither reward
configuration name present. A fresh readback is required immediately before any
approved deployment. The subsequent authorized server publication and successful
signed no-credit Google dashboard verification are recorded in
`QA/admob-deployment-220/README.md` at the repository root. Ads and new quotas
remain disabled; this is not a real-view reward test.

That historical implementation could impose the new quota on build 218, whose
advertising UI is disabled. Candidate 228 replaces this behavior with persistent
account enrollment from supported clients, described below. The gateway's legacy
branch is still pinned to production Base44: a native-only isolated test does not
establish readiness of the legacy route. Activation and any real account test
still require explicit approval.

## Offline checks

Run `deno test --frozen --config supabase/functions/rewarded-generation-ssv/deno.json
supabase/functions/rewarded-generation-ssv/handler_test.ts` from
`experiments/supabase-game-core`. The tests use synthetic signing keys and injected
fetch responses; no provider or production endpoint is contacted.
Also run `deno check --frozen --config supabase/functions/rewarded-generation-ssv/deno.json
supabase/functions/rewarded-generation-ssv/index.ts` to check the deployed entry point.

The existing `tests/game-center/rewarded-generation-integration.ts` suite accepts
only loopback PostgreSQL via `REWARDED_TEST_DATABASE_URL`, creates its own random
database, and drops it in cleanup. It verifies namespaced issuance and the public
gateway along with concurrent grants/spending, exact-once refunds, late callbacks,
unknown provider outcomes, LIMITLESS, and deletion. The public gateway's duplicate
acknowledgment relies on those authoritative ledger checks, not on local memory.

## Unity candidate, 11 November 2026

This gateway now accepts the provider-signed Unity callback in addition to AdMob.
The configuration/activation contract, exact Support callback URL and known
external blocker are documented in
[`base44/functions/generationRewardAction/README.md`](../../../../../base44/functions/generationRewardAction/README.md#unity-release-candidate-prepared-11-november-2026).
Unity SID is an unguessable issued attempt token with a server-owned native/legacy
namespace. A client ad completion cannot grant a credit. Native delivery commits
under the account/quota locks; legacy delivery requires the Base44 response body
`1`. Missing secrets, signature mismatch or malformed upstream success never
acknowledge a reward.

Only this public gateway needs the provider callback URL. Preserve the live
`app-services` entrypoint/router and unrelated deployed game/membership code when
preparing deployment; do not publish the historical full checkout over the live
source. The release preparation keeps an exact live-source-based candidate and
manifest outside the active deployment path. Neither code preparation nor local
fixture tests activate production or establish live Unity callback delivery.

Candidate 228 also requires the `GenerationRewardEnrollment` Base44 schema and
`20261111184822_rewarded_generation_enrollment.sql` private native migration.
Create the Base44 schema before deploying deletion/generation handlers. Only an
authenticated supported status request enrolls an account when Unity and the
global rollout are configured. Old clients remain on their existing policy until
enrollment; subsequent downgrade cannot undo an enrolled account's quota.
