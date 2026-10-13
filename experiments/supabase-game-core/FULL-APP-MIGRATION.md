# Full application migration — build 172 staging

This extends the accepted build 171 game core to the ordinary SpyClash application. It is an isolated staging implementation, not a production cutover. The existing production target still uses Base44. The later authorized Internal Only delivery of build 172 is recorded separately in [BUILD172-TESTFLIGHT-VERIFICATION.md](BUILD172-TESTFLIGHT-VERIFICATION.md).

## Product and provider boundary

The user approved retaining existing Base44 services wherever replacing them would require additional paid setup. No SMTP service, paid Supabase plan, new AI provider, or additional paid infrastructure is part of this change.

| Area | Staging owner | Preservation rule |
|---|---|---|
| Room state and both game modes | Supabase `full-game-core` | Original screens and mechanics; server transactions, immutable requests, private projections and reconnect reconciliation. |
| Saved packs, results, rankings | Supabase `full-game-core` | Owner-scoped packs and result history; original competitive scoring; cursor pagination. |
| Profiles, community, friends, comments, inbox | Supabase `app-services` | Stable account IDs, private contact information, server authorization and recipient-scoped signals. |
| Email login, registration, verification and password recovery | Existing Base44 auth | Preserve existing delivery and six-digit verification; independently verify its bearer before creating a Supabase session. |
| Word generation | Existing Base44 `generateWordPack` | The linked Base44 account owns limits and provider requests. The generated pack can be saved in Supabase. |
| Apple/Google login | Existing provider integration, gated in TEST | The separate bundle/callback must be compatible before enabling it; email login does not depend on new provider setup. |
| Existing subscription contracts | Existing Base44 / Apple provider | Preserve the current weekly product and CASADA policy. Do not introduce a monthly subscription or bill a TEST user. |
| New purchases and remote notifications in TEST | Disabled pending app-identity setup | Existing production Apple/APNs handlers pin the original bundle; Supabase room UUIDs are not Base44 room IDs. Reusing credentials alone does not make these routes compatible. |

The native target is `SpyClashSupabaseStaging`, scheme `SpyClash-Supabase-Staging`, flag `SPYCLASH_SUPABASE`, bundle `com.spyclash.ios.supabasetest`. Its public resource contains only the isolated Supabase URL, publishable key and capability flags. It opens the ordinary Welcome/login/onboarding UI. The older `SpyClashSupabaseTest` fixture-based target remains available for the accepted build 171 evidence.

## Identity and transactions

The Base44 and Supabase credentials are different secrets with different recipients. Native storage separates them by bundle, project and account. Game and application services only accept verified Supabase sessions; `legacy-session` independently verifies Base44 identity with the canonical authenticated `User/me` endpoint. Contact-email equality never authorizes linking accounts. A private reservation stores a random, unreachable shadow mailbox and immutable UUID; server-only Auth create/generate-link/verify operations issue a real session without sending email.

Native restore and token renewal recheck Base44. The server additionally rejects linked Auth sessions older than 65 minutes, even if someone refreshes them directly through Supabase. This bounds source revocation delay without a Base44 call in the game loop; instantaneous cross-provider deletion still needs lifecycle integration for a production cutover.

Private database tables have RLS enabled and no direct client grants. Public Realtime tables carry only recipient- or membership-authorized refresh signals. The server verifies live Auth session membership as well as the JWT, and an account tombstone fences concurrent requests and old tokens after deletion.

Application commands use an immutable UUID and canonical body hash. Domain work runs in a savepoint: definitive rejection rolls back partial writes before its error receipt is stored; an infrastructure failure can be retried with the same intent. Native journals do not persist Base44 bearer fields. External AI, Apple and APNs calls run outside database transactions.

The original game store now separates transport/account lifetime from room lifetime, preventing delayed responses or Realtime callbacks from a previous account from adopting a room. Subscriptions require an actual join acknowledgement. History pagination preserves PostgreSQL microsecond timestamps.

## Data continuity and deletion

Linking an identity and importing its content are separate operations. The first-link importer copies the verified owner's profile/SPY ID, packs and history, records provenance, and preserves subsequent Supabase edits or deletions. It reads at most four history pages per exchange, stores its cursor and withholds the new session until the history snapshot is complete. Repeated login updates only verified private contact information. Old email-only history stays visible without gaining ranked credit; imported results do not create fake playable rooms.

The source pack-list contract has no cursor: 500 or more packs require a separate batch migration. More than 5,000 rows per history ownership query, a changed page anchor, a changed captured result or a SPY ID collision stops with an explicit review requirement instead of silently dropping data. A successful account login does not prove that every legacy social relationship has been migrated.

The separate social migration tool reads `Friendship` and `ProfileComment` directly, without invoking Base44 functions that may repair or write data. The read-only source export captured 5 relationships and 3 comments; its raw contents remain in an ignored local file with mode `0600`. The [aggregate dry run](evidence/full-app/build172/social-import-dry-run.json) intentionally supplies no target mappings: all 8 rows are deferred, and none are applied. This is not a claim that the cloud contains no mappings. The server-only applier requires an authorized operator, a configuration flag and reviewed source IDs; it uses verified legacy IDs, preserves existing local changes and blocks, and never creates users, invitations or pushes. The helper is not exposed through an HTTP route. A cutover needs a fresh, reconciled snapshot and explicit application of its reviewed rows.

Deletion in this isolated build deletes the staging copy and Auth identity. It does not delete the original Base44 account or cancel an existing real subscription. Ownership tombstones prevent a deleted identity or purchase from being reassigned. A durable cleanup job retries Supabase Auth removal after a lost response; automatic background scheduling is a separate operational step.

## Verification and delivery boundaries

The verification record for this change is maintained in [verification.json](evidence/full-app/build172/verification.json). It distinguishes real local Auth/PostgreSQL/HTTP tests with mocked Base44 responses, native XCTest, compile-only verification of the production target, isolated cloud deployment, and real-device acceptance. The ordinary Welcome and email-entry screens were launched and inspected in Simulator; no live Base44 password, verification email or AI generation was used for that UI check.

The isolated deployment contains `app-services` v4, `full-game-core` v5 and `legacy-session` v1, with migrations `20261012235223_full_application_staging` and `20261013002556_hybrid_legacy_identity`. All 24 `app_private` tables have RLS and deny direct anonymous/authenticated reads and writes. The existing [leaked-password-protection warning](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection) remains in Supabase Auth; hybrid email/password authentication uses Base44. Private tables deliberately have no client RLS policies because their data is accessible only through verified server handlers.

Build 171's physical radio-disconnect acceptance remains in [BUILD171-PHYSICAL-VERIFICATION.md](BUILD171-PHYSICAL-VERIFICATION.md). It is not evidence that build 172 has been installed or accepted on Ganzha. No further manual multiplayer session was requested after that acceptance.

For local backend checks, from this directory:

```sh
npm run app:check
npm run app:test
npm run full-core:test
```

The local runner only uses the existing isolated loopback Supabase stack. The cloud check uses existing synthetic accounts on allowlisted project `bbkfsgnordtdiblgdzkg`; it does not provision paid resources or invoke production AI generation.

Final checks passed: 60 application backend tests, 14 game-core tests, 24 distinct native tests across the recorded runs, and 8 isolated cloud verification groups. Both the staging build and the original production configuration compile. The cloud checks include the bridge's rejection paths; a successful live Base44 login/import/generation roundtrip is still unverified.

Before a production cutover, finish the original-bundle provider checks, complete and reconcile the approved legacy social/content snapshot, enable delivery workers as appropriate, and prepare a concrete rollout/rollback operation. Production deployment and an App Store/TestFlight action each require fresh approval for their exact target. This change does not provide that approval.
