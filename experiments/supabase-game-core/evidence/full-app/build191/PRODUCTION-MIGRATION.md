# SpyClash production data backfill — verified report

Date: 19 October 2026. Reviewed code checkpoint: `2dba8d18` (build 191).
Source: canonical Base44 SpyClash application. Target: Supabase project `bbkfsgnordtdiblgdzkg`.

**Status: the approved production data backfill was applied and independently verified.** Explicit approval was obtained in the current chat. The apply request returned HTTP 200, and the target job records `applied` at **11:12:21.205156 UTC**. The final readback passed all seven verification categories, with **zero errors and zero warnings**. Base44 service dependencies described below remain in use.

## Approved scope and verified outcome

The approved packet covers all **26 deployed source entity types and 1,148 original records**. A tracked `AccountDeletionReceipt` schema was independently confirmed absent from the source deployment. Every exported record has a reviewed target disposition and a lossless private archive representation with its original payload and a canonical SHA-256 digest.

| Data | Applied operation | Verified target result |
| --- | --- | --- |
| Accounts | Reserve and provision 56 dormant identities; retain the five previously linked source accounts | All 61 source users represented; 64 profiles including three pre-existing test profiles |
| SPY ID | Preserve all 49 source IDs; assign collision-checked IDs to 12 accounts that had none | No existing SPY ID replaced |
| Profiles | Import missing profiles and retain existing target choices | Names, avatars, card choices, language, onboarding and Radar preference preserved |
| History | Add 113 missing player-result rows; retain all 99 existing target rows | 212 target history rows, without double counting previously imported matches |
| Competitive progress | Reconcile every mapped user against canonical source history and the reviewed target | 135 ranked player-results across source users; aggregate rating 1,040; per-user and role statistics match |
| Word packs | Add one missing owned pack; retain existing target packs and import tombstones | 21 target packs; existing content and ordered words preserved |
| Friendship | Add five mapped relationships with original direction and state | Both endpoints resolve to their immutable target UUIDs |
| Comments | Add three comments with original body and mapped author/target | No comment reassigned by contact email |
| Inbox and moderation | Import two withdrawn announcements, five hidden historical events, nine read receipts and one report | No newly actionable historic notification; prior read state retained |

The complete source manifest has **195 materialized records, 110 records preserving an existing target representation, and 843 archive-only records**. Archive-only records include provider-owned data, transport/transient state, old rooms, and records whose original owners no longer exist. In particular, **two orphaned word packs and five orphaned history rows** are retained with their original ownership in the private archive; they are not attached to another account through a matching email.

The 12 source User counter discrepancies are stale zero mirrors. The application calculates visible progress from canonical history. Importing the real history preserves progress without adding mirror counters or granting duplicate ranked credit.

## Dormant-account and data protections

The 56 new Auth identities use their persisted immutable reservations and private random shadow mailboxes. The import does not treat an email match, a copied profile, or a SPY ID as proof of account ownership. Previously linked identities retain their UUIDs. Deletion fences and conflicts block application.

For a never-authenticated imported account, `import_completed=true` describes data readiness only. The expected state remains `reserved`, without a fabricated verified link or verification timestamp. The next real sign-in must verify the user's current Base44 credential and adopt the reserved UUID before issuing a session. Local tests exercised the existing bridge adoption path; real user sign-in after this production import is a separate observation.

The importer uses Auth Admin creation without invitation or session endpoints, replays no push-delivery operation, and resets no history, progress or AI quota. Production readback confirms **zero sessions and zero push-outbox rows for the 56 new identities** (rechecked at 11:16:17.506353 UTC), 61 immutable reservations and only the five pre-existing verified legacy links. Both imported announcements remain withdrawn and all five imported personal events remain hidden. Existing target profiles, packs, history and social records match their reviewed preimages; no history or progress reset occurred. The unchanged full Base44 postflight capture also preserves the provider-owned quota and delivery records.

## Base44 services that remain in use

This operation is a complete data backfill and preservation pass, **not removal of all Base44 service dependencies**. Existing bridges still use Base44 for sign-in verification, Apple purchase verification/revocation and billing ownership, AI generation and usage/quota enforcement, push delivery, and original-account deletion.

Their source records are preserved in the private archive while the existing provider remains authoritative. Copied entitlement records are not treated as fresh purchase verification. Encrypted Apple/device/activity records are not activated with new credentials or replayed through another worker. Base44 must remain available until these services have separately been replaced and verified.

## Evidence already available

- The reviewed packet has zero blocking core or ancillary issues and preserves the same immutable mailbox/UUID reservations throughout retries.
- The complete private source snapshot and target baseline were rehearsed in a separate local PostgreSQL database: 16/16 integration checks passed, including sealed HTTP upload, Auth failure/recovery, lost acknowledgement, source attestation, target drift, atomic archive failure rollback, idempotence and safe rollback.
- The synthetic rehearsal passed 15/15 checks; the core tests passed 18/18. Temporary rehearsal databases were removed.
- Local real Auth Admin API checks were performed separately by the operator. The full-data rehearsal mocked Auth transport and Base44 credential verification, and is not represented as a live production sign-in test.
- The private postflight verifier passed five self-checks, detecting deliberately corrupted archival payload, changed SPY ID, changed history and a missing friendship.

## Production verification results

| Verification | Status |
| --- | --- |
| Final apply HTTP response and private job status `applied` | **Passed:** HTTP 200; committed at 11:12:21.205156 UTC |
| Readback of all 61 immutable mappings and all planned SPY IDs | **Passed:** 49 existing IDs preserved; 12 newly allocated IDs match the reviewed plan |
| Profile/history/pack/social records and existing target data preserved | **Passed:** 64 profiles, 70 Auth identities, 212 history rows, 21 packs, five friendships and three comments |
| Per-user ranked and role progress reconciliation | **Passed:** every mapped user's expected values match; aggregate 135 ranked player-results and rating 1,040 |
| Every one of 1,148 archived payloads, independently recomputed digest and disposition | **Passed:** every original payload matches, each SHA-256 recomputes correctly, and every disposition matches the sealed manifest |
| Dormant-account verification/session state and notification projections | **Passed:** zero new-identity sessions, no fabricated verified links, five hidden historic events and no newly actionable notification |
| Final Base44 re-export to detect any change between source attestation and target commit | **Passed:** complete scans at 11:12:58.099–11:13:12.183 UTC; schema verification at 11:13:13.137 UTC; all source content and schemas unchanged |
| Operator capability expired after successful postflight | **Passed:** operator recorded expiry at 11:13:43.927105 UTC; the former capability was rejected with HTTP 401 at 11:14:18.053 UTC |

The postflight verifier was independently rerun against the private SQL readbacks and all archived payload batches with the same seven-category pass and no errors or warnings. The fresh Base44 snapshot integrity hash and the complete canonical source/entities/schemas digest were also independently recomputed and matched the approved source content. No raw identifier, contact detail or credential was needed in the sanitized result.

Raw payloads, contact information, encrypted credential material, private mailboxes and operator capabilities are excluded from this report. They remain in restricted, gitignored private evidence and private database tables.

Rollback remains a separately authorized operation. It must reject newer user activity and retain immutable reservations; it must not cascade-delete an Auth identity that has subsequently signed in. No rollback was performed.

## Previous-email ownership confirmation

The user additionally requested that every ID stay attached to its original owner's email. A fresh production SQL join between the archived source User row, the sealed UUID mapping, current profile and immutable reservation passed at **11:19:18.984490 UTC**: **61/61 exact original-email matches**, zero missing emails, zero duplicate email groups, zero owner-mapping mismatches and zero changed pre-existing SPY IDs. No corrective reassignment was necessary. The original email is stored as `profiles.contact_email`; the old Base44 principal, target UUID and SPY ID retain their reviewed association.

Auth uses private shadow mailboxes under the existing credential bridge. Replacing these addresses with contact emails would violate the bridge's ownership checks and is not part of this migration. The deployed `legacy-session` version 3 entry point, identity service, provider verifier, importer and crypto code match the reviewed implementation. An unrelated `profile.ts` signal-query optimization differs from the migration worktree; it does not change reservation adoption or email ownership. The importer never equates matching email alone with authenticated ownership.

## Verification boundaries

These production results prove the actual database contents and each source-to-target mapping. This turn did not sign in as an imported person or verify a physical iPhone. A bounded search found no current credentials for the three old QA fixture profiles, so no authenticated community HTTP reader test was performed. Existing QA actor files contain stale IDs; no fixture account was recreated and no user's credentials were changed to obtain access. Read-handler behavior and first verified reservation adoption remain covered by the reviewed implementation and local rehearsal, not a newly observed production user sign-in.

The deployed temporary migration function remains installed with its job capability expired. The archive, provenance and rollback journal remain private. No TestFlight or App Store action was performed. See [machine-readable production evidence](production-summary.json) for sanitized counts, timestamps and digests.
