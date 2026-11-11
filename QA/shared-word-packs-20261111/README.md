# Shared word-pack library — build 229

Status: **activated on the production server on 11 November 2026 after explicit approval in this chat**. Supabase `app-services` is now version 20; Base44 `generateWordPack` and both shared-library flags are configured. See `activation.json` for the deployment receipt.

The feature reuses generated words across accounts through one Supabase library. Both the Base44 generator and native Game Center generator check the same exact normalized theme / theme-language policy / generator-version key before calling a model. Matching folds case, whitespace and Unicode compatibility; it does not infer topic aliases or merge different scopes. The existing theme-derived language policy is preserved.

Usable words from multiple valid variants are combined, deduplicated and filtered against the request's exclusions. An explicit `prefer_fresh` request still checks for unused shared words. A model runs only after a successful lookup establishes insufficient suitable stock and the server owns the topic lease. Requests for the same new topic compete for one five-minute lease; uncertain in-flight provider outcomes retain that lease until expiry.

## Points and recovery

- A library hit returns the ordinary successful generation response and consumes the same daily allowance or earned bonus credit as a model-generated pack.
- Replaying the same completed request UUID returns its saved result without spending another point.
- Existing unlimited membership behavior, quota limits and advertising feature flags are preserved. This feature does not independently activate quotas or ads.
- A library lookup failure does not authorize a model call. Base44 rejects it before the paid operation; native generation releases the unspent reservation.
- Native publication and successful request completion commit atomically. Provider output is durably journaled so a failed publication can recover without a second model call.
- Base44 publishes after its successful result becomes replayable. Publication is best effort: a failed library write preserves the successful result and its charge, but that particular pack can remain absent from the shared library. There is no publication outbox in this version.
- Known temporary shared-library errors are retried with the same request identity by the updated clients. Unknown provider outcomes keep the existing conservative recovery rules; they are never treated as permission for another paid call.

## Storage and access

Migration: `experiments/supabase-game-core/supabase/migrations/20261111185732_shared_word_pack_library.sql`.

Two new tables contain generated words / matching hashes / version / timestamps and topic leases. They do not contain raw theme or exclusion text or account identifiers. Existing private caches and manually saved packs are not backfilled. Variants remain eligible for reuse for 30 days; physical cleanup is opportunistic on later publication for that topic, not guaranteed deletion at day 30. The app's disclosure has been updated in all four supported languages.

RLS is enabled. Anonymous and authenticated client roles have no table or RPC access. Only the server service role uses the REST RPCs; the native server calls the same functions through its database connection. No privileged key is added to the iOS app.

## Verification

All providers and ad rewards in automated checks are fixtures. SQL checks create and destroy dedicated databases on loopback PostgreSQL; they do not modify the running local application database or hosted projects.

- Base44 generator regression suite: **138 tests and 23 actual-handler steps passed**, including cache/point/replay scenarios.
- Shared helper tests: exact keys, combined variants, exclusions, quality, expiry, clock skew and exhausted themes.
- REST adapter tests: secret-key headers, malformed/error responses, lease races and cleanup.
- Native generation integration: **10 PostgreSQL checks passed** for cross-account hits without AI, daily and bonus points, request replay, read failure, concurrent miss, publication recovery, definitive failure refunds and unknown outcomes.
- SQL access/concurrency: **6 PostgreSQL checks passed** for denied client privileges, service-role access, atomic claims, stale-worker fencing and 1,002 returned variants without result clipping.
- Existing native rewarded-generation regression: 23 checks passed.
- Both prepared server candidates type-check. Base44 function bundle isolation passes.
- Base44 client retry/recovery: **11 focused Swift tests passed** (including one corrected test-fixture rerun); identical request payload and UUID were verified across retryable responses.
- Native client retry: **15 focused Swift tests passed** (7 new generation-retry checks and 8 existing App Store retry checks), with actual test discovery and no skips.
- Signed Simulator build of `SpyClash` succeeds. Compilation is not a device, TestFlight or production acceptance result.

Local logs and exact deployment candidates are under `.local/shared-word-packs/`. `rollout-manifest.json` records immutable source hashes and the inspected live server baselines. The candidates preserve unrelated deployed code rather than deploying the entire working branch.

## Production activation completed

The user explicitly approved the following named operations in this chat, and all four are complete:

1. Apply the single additive migration to Supabase project **spyclash-game-core**, `bbkfsgnordtdiblgdzkg`.
2. Deploy the prepared **app-services** function candidate to that project, preserving its existing JWT verification and unrelated deployed source.
3. Deploy only **generateWordPack** to Base44 app `69a0e57fa939f578082f8091`.
4. Configure Base44 server-only `SPYCLASH_WORD_LIBRARY_SUPABASE_URL` and `SPYCLASH_WORD_LIBRARY_SUPABASE_SECRET` for that Supabase project, then enable `SPYCLASH_SHARED_WORD_PACKS_ENABLED=true` on both backends. This is the only new rollout flag; do not change existing quota/ad flags.

Live baselines were re-fetched and matched before deployment. After deployment, both function sources matched their approved candidates. Server REST reads returned 200; direct client RPC access returned 401. Both tables and all four RPCs deny anonymous/authenticated roles and allow the server role. A transaction on the live database verified claiming, publication, readback and fencing, then rolled back all test records. The generation endpoint still rejects unauthenticated requests. Existing Supabase configuration digests were unchanged except the new rollout flag.

A paid generation and point deduction on real user accounts were **not** exercised during activation. Their behavior was verified by the local handler, PostgreSQL and client tests above. The Supabase security advisor reported only the expected informational RLS-without-policy notice for the server-only library; client access remains revoked. No new iOS App Store/TestFlight build was published, so the client retry enhancements arrive with build 229 when it is released.

Rollback: set the shared-library flag to false on both backends. Keep the additive tables and durable account request records; do not delete charged-operation history. App Store/TestFlight publication is a separate action and is not part of this prepared server activation.
