# Public account deletion: server preparation for build 200

The signed public client 1.0.3 (200), commit `da2e8584`, remains unchanged. This backend-only follow-up is prepared separately for checkpoint 201. Nothing in this document records a production deployment or successful real-account deletion.

## Confirmed gap and resulting behavior

Live main Supabase was `app-services` v10 / `full-game-core` v7. Its `main_account_deletions` table was absent. Live Base44 `deleteAccount` had no receipt protocol. The internal Game Center overlay deliberately pins `APP_MAIN_ACCOUNT_DELETION_ENABLED=false`; it is unsuitable for the public client's enabled full-account deletion.

The prepared protocol now uses `spyclash-deletion-receipt-v2`. A verified Base44 immutable user ID must match the private Supabase link. A new client request UUID after journal loss resumes the existing server intent and provider capability. Provider 401, absence of a bearer, or unverified JSON never proves deletion. Supabase clears its account only after the exact provider receipt is complete.

Archive erasure covers `bulk_migration_archive`, source-row ledger entries, nested sealed-job snapshot/plan/baseline copies and affected rollback journal entries. Shared containers retain unrelated participants. A foreign stable owner wins over matching email/Apple selector. Aliases come only from archived `User` records with the verified immutable legacy ID; conflicting historical ownership fails closed. Active affected migration jobs block before provider deletion. Sealed import capabilities expire when their payload is redacted, and the user's rollback entries are removed so a future rollback cannot restore the account.

Base44 receives these historical aliases only in an independent HMAC-signed server request. It derives opaque Apple selectors with its existing historical `SPYCLASH_PSEUDONYM_KEY`; that key is never copied to Supabase. A currently reassigned alias cannot create new selector evidence. Previously completed private receipt evidence remains usable after subsequent email reassignment, so a lost acknowledgement can still finish erasure. Receipts retain an alias-list digest, not raw emails. Supabase clears temporary proof in the same transaction that marks deletion complete.

The same verified aliases remove old email-only GameHistory/WordPack content and referenced ephemeral GameRooms from Base44. Stable foreign owners/participants are preserved. Existing ordinary clients without the new signed request keep their previous deletion contract.

## Exact prepared changes

Deploy only the reviewed folder `experiments/supabase-game-core/base44-prepared/deleteAccount` to Base44 app `69a0e57fa939f578082f8091`, with entity `base44/entities/account-deletion-receipt.jsonc`. The folder preserves the freshly read live support-module versions. Its intentional additions are receipt recovery, signed archive proof/read-only probe, and historical content cleanup. Do not deploy every local Base44 function or replace its support files with unrelated canonical-folder changes.

Main Supabase target is **only `bbkfsgnordtdiblgdzkg`**. Required additive migrations, in order:

1. `20261013010810_main_account_deletion_intent.sql` — previously prepared 199 durable intent.
2. `20261026172415_main_game_center_identity.sql` — main Game Center private identity and generation tables.
3. `20261026232916_public_deletion_archive_erasure.sql` — temporary private `erasure_proof` column.

The public source overlay must preserve the same frozen live engine/push/worker/live-activity files as the internal overlay. Remove the internal hard-false deletion pin only in this reviewed public package. Native Game Center deletion remains a separate server-owned identity path; it does not require a Base44 receipt or borrow a legacy account.

## Configuration and safe rollout order

All production actions below require the exact reviewed package approval; these are preparation instructions.

1. Apply the additive private migrations. Check RLS and grants; no user-facing role receives archive, intent or identity-table access.
2. Create/update only the private Base44 `AccountDeletionReceipt` entity and deploy the prepared `deleteAccount` folder. Keep public full deletion disabled. The previous ordinary deletion contract remains available.
3. Configure a new independent 32-byte random secret as hex `APP_DELETION_ARCHIVE_SECRET` on Base44 and Supabase. Keep the Supabase `APP_DELETION_RECEIPT_SECRET` stable for pending intents. Do not replace or export Base44 `SPYCLASH_PSEUDONYM_KEY` or Apple token-encryption/revocation keys.
4. Run the read-only historical-key verification below while `APP_DELETION_ARCHIVE_KEY_VERIFIED` is absent/false. Do not set this marker merely because a key exists or has a valid format.
5. After positive historical binding evidence, set Base44 `APP_DELETION_ARCHIVE_KEY_VERIFIED=true`. An unauthenticated `deletion_capabilities` request must then report exactly v2. With a missing key/marker it returns unavailable before any account fencing.
6. Deploy the reviewed public Supabase app-services/core/Game Center overlay, configure its explicit feature gates, and enable `APP_MAIN_ACCOUNT_DELETION_ENABLED=true`. Configure an authenticated bounded maintenance runner for pending provider receipts and Auth cleanup; no pg_cron scheduling was present in the read-only live inspection, so an external runner needs separate verification.
7. Probe missing/forged Game Center assertions and unauthenticated app requests, and re-read versions, migrations, logs and security advisors. These negative checks must create no accounts or profiles. Verify real full deletion only with a separately authorized disposable ordinary account; an administrator/app-owner is not a valid acceptance fixture. Keep the user's installed QA session intact.

## Historical selector verification without extracting the key

`POST /api/apps/69a0e57fa939f578082f8091/functions/deleteAccount` supports the **read-only** action `deletion_archive_probe`. It creates no receipt, deletes no records and does not require the readiness marker. It does require a valid server HMAC and rejects unsigned, stale, changed-subject or changed-alias requests. The signing key is the new independent archive secret, not any Apple/global pseudonym key.

Use a read-only query to select a credential with nonempty `payload.user_id`, then join archived `User.payload.id` to that exact ID within the canonical source. Reject conflicting User aliases or a foreign nonempty credential owner. Preserve raw emails and selector values only in an ignored restricted local file/tool memory; logs should contain counts and pass/fail only. There was one bound archived Apple credential and 28 unbound credentials in the preflight snapshot (29 total), so this supplies a positive historical test, not an email-only ownership guess.

For each chosen immutable subject and its sorted unique lowercase archive aliases, make:

```json
{
  "action": "deletion_archive_probe",
  "request_id": "<new UUID>",
  "archive_erasure_request": {
    "aliases": ["<verified archived alias>"],
    "subject_hash": "<SHA256(spyclash-delete-user-v1:legacyUserID)>",
    "timestamp": 0,
    "signature": "<HMAC-SHA256 as lowercase hex>"
  }
}
```

The timestamp is current Unix milliseconds, within five minutes. Sign UTF-8 `JSON.stringify(["spyclash-deletion-archive-v1", request_id, subject_hash, aliases, timestamp])` with the independent archive secret decoded from hex. Send JSON only to the fixed canonical origin, with redirects disabled; never put secret/capability data in a URL. The response contains `erasure_proof.apple_identity_keys` and `archive_alias_digest`, without credentials or raw aliases.

A successful HTTP response is insufficient. At least one returned selector must exactly match the archived bound credential's `identity_key` for the same immutable subject. Where multiple historical selector versions or aliases exist, verify each relevant version; unexplained rows remain a blocker requiring ownership investigation, not deletion by email equality. For coverage, derive selectors for archived immutable User subjects and compare the returned key set with unbound archived keys, preserving foreign-bound credentials. Report matched/unmatched counts, never token material. If positive historical matching fails, leave both readiness/enabled flags off. Do not solve the mismatch by generating a replacement pseudonym key.

## Verification recorded locally

- 24 focused Node tests passed, including genuine local Auth/Postgres deletion, lost-journal/new-UUID recovery, lost provider acknowledgement, concurrency, historical email changes, unbound Apple archive erasure, mixed-container preservation, signed-request tampering/staleness, current email reassignment and completed-proof recovery.
- 40 Base44 deletion regression tests passed, including historical content/room owner precedence and the read-only probe/readiness gate.
- Prepared Base44 entry and Supabase app-services typechecks passed.
- Tests use only local `127.0.0.1:56321/56322`, preserve other test data and clean only their own fixture IDs. Run DB suites serially (`--test-concurrency=1`) because their existing schema bootstrap uses DDL.
- Fresh original Base44 re-read after the CLI eject incident: `deleteAccount` entry SHA256 stayed `db06e45624aef90d869fcff90c97cd09807d742ae28c203d58ccf0db0f314197`; all original support files matched the earlier read. This is source equality evidence, not evidence that an untracked deployment never occurred.

No real Apple/Game Center assertion, physical-device deletion, production schema change, production secret configuration or public App Review acceptance is claimed by these local results.
