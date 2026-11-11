# Word-pack names and reuse — build 232

Status: **server changes published on 11 November 2026 after explicit approval in this chat**. Supabase `app-services` is ACTIVE at version 23; both Base44 generators match the approved candidate. Build **1.0.4 (232)** is now available in the internal TestFlight group after separate explicit approval; see [delivery evidence](../testflight-232-20261111/README.md). No App Store release or paid live generation was performed.

Base: `ee3037ec` (generation-library-recovery-231). The default checkout was an older build-149 branch; work was isolated on `davidganzha/word-pack-names-232` so the current product and generation-recovery changes are retained. Marketing version remains 1.0.4.

## Confirmed causes

1. The older checkout had the punctuation fix `7008b2eb`, but the current integrated app did not. `WordPackDraft` joined generated array items with newlines and then split them on commas/semicolons again. Saving/reopening a name such as `Маления, Клинок Микеллы` therefore produced separate entries.
2. The shared library discarded a non-exhausted partial pool when its size was below the requested count. Both servers then generated the entire count again, allowing existing entity names to change.
3. The Base44 generator used cache version `whole-items-v2`, while the native direct and relay provider copies used `single-pass-theme-language`. Equivalent themes could therefore use separate shared library keys.
4. The naming prompt allowed official spelling or recognized transliteration without prioritizing one established localized name or explicitly treating aliases as the same entity.

A read-only production query on 11 November found two variants under the same Elden Ring-related shared key: 30 items at 21:07:13 UTC and 31 at 21:28:46 UTC. Several entity names differed; the first included both `Богошкурый дуэт` and `Двое из кожи богов`. Names with commas were still complete server array entries. No account identifiers, user messages, quotas or production records were changed by this inspection.

## Changes

- Generated and reopened packs retain their array boundaries. Adding/removing names keeps commas and semicolons within each entry. New manual comma-separated entry remains supported, with format-specific input guidance in all four languages.
- Both generation backends keep eligible shared words and request only missing additions (the provider's minimum request is two). User exclusions, exact theme scope, validity windows and topic leases remain enforced.
- Native top-up reconstruction data is stored separately from completed results. Durable provider retries keep their original seed and input, including when library contents change or the feature is disabled. Unspent retries may use newly available complete stock.
- All three provider copies share `canonical-names-v3`. Previously cached variants are excluded from new generation. Naming rules prefer established localized names, preserve punctuation, and prohibit returning alternate names for the same entity, including excluded entities.
- Public exclusion limits are unchanged. Internal provider exclusions allow 300 entries to accommodate the original 200 exclusions plus retained/verified words.
- Existing request identity is preserved across cache invalidation. New naming policy does not authorize repeating a paid request or discarding its saved result.

## Limits

Prompt instructions are not an external factual database or deterministic semantic alias checker. Real generation quality still needs acceptance testing after an approved rollout. Topic matching remains exact after case/whitespace/Unicode normalization; paraphrased topics are not automatically merged.

Already-split saved packs lack enough information for safe automatic repair. This change prevents future splitting; existing damaged packs need editing or regeneration. Existing paid request results remain replayable even if generated under the previous naming policy.

## Approved publication scope

The user explicitly approved the following operations in this chat; all are complete:

1. Apply the additive private `generation_requests.seed_words` migration to Supabase project `spyclash-game-core` (`bbkfsgnordtdiblgdzkg`) before deploying the new worker.
2. Update only `app-services` in that project, retaining its JWT verification and unrelated live source.
3. Update only Base44 `generateWordPack` and `nativeGameCenterWordPack` in app `69a0e57fa939f578082f8091`.

The three generators should be updated in one approved rollout to converge their shared namespace. No relay wire/hash version changes, secret changes, quota/ad flag changes or user-data backfill are required. Old versioned variants remain stored until ordinary expiry but are not reused by new requests.

Fresh live source snapshots and prepared overlays are under `.local/word-pack-names-232/`. The overlay preserves the live reward-enrollment behavior rather than publishing unrelated branch changes. A rollback can restore the saved runtime files; keep the additive column and paid-operation history.

The punctuation fix is an iOS change. Its separately approved delivery is complete in TestFlight build 232; testers must install that update to receive the editor fix.

## Final verification

- **218 tests passed:** 18 signed iOS Simulator tests, 149 Base44 generator tests, 18 native PostgreSQL integration checks and 33 existing rewarded-generation checks. The Base44 suite also executed 29 real-handler fixture steps.
- All three exact live-overlay function candidates type-check. Base44 function bundle isolation passes; independent review found no remaining blocking issue.
- The native database tests use disposable databases on `127.0.0.1:56322`. Providers, rewards and HTTP responses in tests are fixtures. No paid production generation or device acceptance test was performed.
- `candidate-manifest.json` records ten runtime overlays against fresh downloaded server code; every unrelated downloaded file was preserved. It includes the unapplied migration hash.
- Simulator evidence: `ios-tests.json`, result bundle `/tmp/SpyClash-word-pack-names-232-tests.xcresult`. Full summaries: `verification.json` and the included logs.

The initial bundle-isolation invocation used the wrong shell and was rerun with its required zsh; it passed. The old standalone cross-platform quality-contract test still references a missing untracked web checkout and stale call-site text; it was not used as evidence. The new standalone provider-parity test and the full generator suite run without that checkout.


## Production verification

- The freshly fetched live baselines matched the prepared versions before publication. The migration added only the nullable private seed column and its constraint; RLS, table grants and the completed-result invariant remain intact. Supabase registered the exact migration SQL as `20261111221629_generation_shared_seed`.
- Published in order: migration, Base44 native relay, Supabase `app-services`, Base44 standard generator. The relay-first order prevents the new worker from publishing old relay naming output under the new cache key.
- Supabase returned ACTIVE **version 23**, with JWT verification enabled. All **74** read-back files exactly match the approved upload.
- Base44 read-back matches all **18** standard-generator and **6** relay runtime files. All **20** unrelated functions remain byte-for-byte unchanged.
- All three unauthenticated endpoint probes returned **401**, before any generation work. This checks publication/authentication, not real generation quality or point deductions.
- The first relay deployment was rejected for the pulled archive entry-path layout. The CLI package was flattened without changing any runtime file bytes; the named relay retry and subsequent standard-generator deployment each reported exactly one function deployed.
- No secret, quota/ad flag, existing user pack, or request history was modified. The iOS punctuation fix was subsequently delivered in TestFlight build 232.

The post-migration security advisor reported informational RLS-without-policy notices for server-only tables, plus an unrelated [disabled leaked-password protection warning](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection). This rollout did not change authentication configuration or client privileges.

Receipts: `deployment.json`, `base44-postflight.json`, `postdeploy-auth-probes.json` and deployment logs.
