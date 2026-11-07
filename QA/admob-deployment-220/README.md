# Rewarded generation server publication — 7 November 2026

The user explicitly approved publication to Supabase and Base44 and connection of AdMob SSV, with advertisements and new generation limits remaining disabled.

## Published server support

- Base44 app `69a0e57fa939f578082f8091`: added `GenerationReward`, published `generationRewardAction`, `generateWordPack` and `deleteAccount`. All 39 returned TypeScript files match the reviewed package; 27 existing schemas and the source/configuration of 19 other functions were preserved.
- Supabase project `bbkfsgnordtdiblgdzkg`: applied the reviewed reward migration, published the minimal `app-services` package with JWT verification enabled, and the separate public callback with Google signature authentication.
- The migration service registered the SQL from `20261105224817_rewarded_generation_credits.sql` under **`20261107190551_rewarded_generation_credits`**. This is the already-applied migration; do not blindly republish the older filename timestamp.
- Both backends were configured with `SPYCLASH_REWARDED_GENERATION_ENABLED=false` and unit `ca-app-pub-5081830513960558/6816674766`. Supabase readback digests matched both values. Base44 acknowledged setting the exact values and exposes their names/masks only, so its runtime environment value was not independently retrieved.

Publication receipts: [Base44](base44-publication.json), [initial Supabase publication](supabase-initial-publication.md). Root independently confirmed both unsigned callbacks return HTTP 400 and app-services without authentication returns HTTP 401: [endpoint checks](unsigned-endpoint-checks.json).

## Dashboard verification adjustment

AdMob requires a successful dashboard URL verification before it allows saving the callback. Its first signed test reached the strict handler and returned HTTP 400 because the test is not an issued reward attempt. Sanitized request metadata showed the reserved test markers, reward `1 generation`, and synthetic ad unit **`1234567890`**, rather than our owned unit.

Source checkpoint 220 adds a narrowly scoped no-credit response. Google's signature must verify first. Both reserved markers (`spyclash_admob_setup_probe`, `spyclash_setup_probe_v1`), that observed synthetic unit and `1 generation` must match; a valid owned unit must also be configured. The response reports `setup_probe:true` and `reward_granted:false`, returning before either ledger or Base44 forwarding. Other callbacks retain their existing exact attempt/user/token/unit/reward and replay checks.

All **13 gateway tests** passed with the frozen dependency lock; the callback entrypoint passed type checking. Tests cover signature tampering, signed marker/unit/reward mismatches, missing configuration, disabled offers, repeated probes, zero ledger/forwarding calls, and unchanged ordinary routing. iOS source changed only its required build metadata to 1.0.4 (220); no iOS distribution was performed.

## Final readback

- Callback v2 was published with only `handler.ts` changed in the existing ten-file dependency graph. All returned files matched the reviewed candidate; app-services v19, JWT settings and the disabled feature flag remained unchanged. See [callback publication](supabase-callback-publication.md).
- At **19:14:31 UTC / London**, the real Google dashboard verifier received HTTP 200 from the signed no-credit probe. AdMob displayed **Success! Your callback URL has been verified.** See [sanitized delivery evidence](google-signed-setup-verification.json).
- **Use verified url → Save** completed. The saved Server-side verification row showed `https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv`; reward remained `1 generation`. No mediation-wide setting or other ad-unit option was changed. See [saved settings readback](admob-saved-settings.txt).
- After the check, Supabase had **0 issued attempts / 0 earned rewards**. Base44 had **0 GenerationReward records** at 19:15:30 UTC: [final Base44 count](base44-reward-count-after-verification.json).
- Both feature switches remain false. No advertising or new daily limit was activated.

## Remaining scope

The dashboard probe proves signed delivery and connection, not a real advertisement or reward grant. No ad-enabled iOS build, real ad view, production generation request, issued reward attempt or bonus grant is part of this publication. A controlled real-view test and the separate activation prerequisites in the [publication plan](../../release/ADMOB-SERVER-PREPARATION-219.md) remain for a later authorized rollout.
