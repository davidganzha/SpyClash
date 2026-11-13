# Authorized server rollout — build 238

Completed on 13 November 2026 after the user's explicit approval in the current
chat for these seven functions and two additive schema operations. No rollout
flag, secret, Unity activation, monthly activation, website publication, or
other app was changed by this server operation.

## Applied and read back

| Target | Result | Exact candidate files | Access |
| --- | --- | ---: | --- |
| Supabase app-services | v26 → **v27** | 84 | JWT required, preserved |
| Supabase full-game-core | v16 → **v17** | 51 | JWT required, preserved |
| Supabase rewarded-generation-ssv | v3 → **v4** | 11 | Public signed callback, preserved |
| Base44 app-store-entitlement | deployed | 16 | Existing automations preserved |
| Base44 generateWordPack | deployed | 18 | Existing automations preserved |
| Base44 generationRewardAction | deployed | 9 | Existing automations preserved |
| Base44 deleteAccount | deployed | 15 | Existing automations preserved |

Supabase project: `bbkfsgnordtdiblgdzkg`. Base44 canonical app:
`69a0e57fa939f578082f8091` (SpyClash). All **204 deployed file instances** were
read back and compared byte-for-byte with the approved candidate bundles.
Every target receipt records its version/deployment ID, count and comparison.
The earlier 168 candidate checks remain the test evidence; no redundant suite
run or real purchase/ad was performed during deployment.

The native enrollment migration used the exact source
`experiments/supabase-game-core/supabase/migrations/20261111184822_rewarded_generation_enrollment.sql`
(SHA256 `4e83b4bb81db338d5331b7134f8a2964110c51afbff5476b4d048a847b2c3536`).
Supabase recorded the applied migration as **20261113101004**,
`rewarded_generation_enrollment`. Readback confirms RLS is enabled and both
anon and authenticated roles have no SELECT/INSERT/UPDATE/DELETE privileges.

Base44 added only **GenerationRewardEnrollment** through the documented
`POST /api/apps/{app_id}/entity-schemas` operation with `entity_name` and
`entity_schema`. The schema matches the approved local file exactly. All 28
previous schemas, including User's custom schema, remained identical; the
total is now 29. Bulk schema PUT was not used: its official contract replaces
the complete schema set. See the [official API contract](https://app.base44.com/api/openapi.json).
The schema source is tracked in the repository; future complete Base44 code
syncs must retain it because live schema API changes can be superseded by a
later source rebuild.

## Preservation and smoke checks

Fresh preflight found no live drift: Supabase versions/bundle hashes matched
the prepared baselines, and all 22 Base44 function bundles, entrypoints and
automations matched the saved snapshot. After deployment, the four intended
Base44 targets match their candidates, all other **18 function bundles** remain
identical, and all previous schemas remain identical. At 10:16 UTC, the
canonical app's website publication metadata was unchanged.

Read-only unauthenticated smoke checks at 10:17 UTC returned:

- app-services: 401 `UNAUTHORIZED_NO_AUTH_HEADER`.
- full-game-core: 401 `UNAUTHORIZED_NO_AUTH_HEADER`.
- rewarded-generation-ssv: 400 `invalid_reward_signature`.

The first two establish gateway access protection; they do not prove an
authenticated user flow. The public callback response establishes that the
new callback runtime loads and rejects an unsigned request. No user account,
entitlement, generation balance, payment provider, or ad impression was mutated
by these checks. Real device purchase/restore and Unity signed callback
acceptance remain separate evidence.

## Operation boundaries and remaining activation

Supabase used only the scoped `apply_migration` and `deploy_edge_function`
operations. Base44 used the additive schema POST and four per-function
`PUT /backend-functions/{name}` requests with exact entry/files/automations.
The Base44 plugin's read tool was unavailable, so these requests followed the
verified official API/installed CLI implementation directly; no Base44 CLI,
eject, app-wide deploy, publish, or creation operation was used.

The preflight configuration audit found no Unity S2S secret, game ID,
placement ID, or provider selection in Supabase, while the global rewarded
generation flag matched false. The monthly checkout flag was absent. This
operation did not change any of those settings.

Remaining prerequisites are separate approved actions:

1. Unity must activate S2S and provide its real secret. Configure both backend
   owners with provider `unity`, game `800429660`, placement `BP_Rewarded_iOS`,
   and the server-only secret; then verify actual native and legacy callbacks.
2. Enable `SPYCLASH_REWARDED_GENERATION_ENABLED=true` only after its approved
   rollout conditions. Until activation/enrollment, existing native free
   accounts keep ten daily generations. The three-free policy and one credit
   per verified ad are deployed but not globally activated.
3. Complete/verify the monthly product's Apple readiness, then separately
   authorize `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED=true` on both
   applicable backends while preserving the existing master purchase gates.
   Keep the historical `APPLE_IAP_PRODUCT_ID` configuration; do not replace it
   with monthly. Existing weekly/monthly restore support is deployed and does
   not depend on the new-checkout flag.

## Evidence location

Sanitized receipts are in this directory. It has mode 0700; receipt files are
0600. Raw preflight app/function/schema snapshots, exact Base44 requests and
readbacks, and three Supabase readbacks are under
`.local/server-rollout238/`, with private records at mode 0600. No credentials
or secret values are included in the committed receipts. The release manifests
and patches remain under `QA/app-store-complete-238/rewards/` and `monthly/`.
