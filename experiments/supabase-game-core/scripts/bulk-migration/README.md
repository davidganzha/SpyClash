# Complete Base44 data backfill — build 191

This is an operator migration package for canonical Base44 app
`69a0e57fa939f578082f8091` → Supabase project `bbkfsgnordtdiblgdzkg`.
Preparation and local rehearsal do not authorize production execution.

## Reviewed outcome

The independently enumerated source has 26 deployed entity types and 1,148 rows.
All source rows receive an explicit disposition and a lossless private archive
copy with a canonical SHA-256 digest. The tracked `AccountDeletionReceipt`
schema is not deployed; it is recorded as absent, not as an empty live table.

The initial reviewed plan creates 56 dormant Auth identities and profiles,
preserves the five already linked user profiles, preserves 49 existing SPY IDs,
and allocates collision-checked IDs for the 12 users without one. It adds one
owned word pack, 113 history rows, five friendships and three comments. It also
materializes two withdrawn announcements, five hidden historic events, nine
read receipts and one moderation report. No old notification is delivered.
Three pre-existing cloud test profiles remain untouched: the expected active
profile count is 64 (61 source users plus those three fixtures); directory
responses remain paginated.

The seven owned-data rows without current source owners (two packs and five
history rows) stay archived with original ownership. Source users are never
recreated from email-only references. Existing target edits, removed content,
account tombstones and current progress take precedence. Twelve source User
counter mirrors are stale zeros; actual history-derived games/wins/rating match
the resulting target for all 61 users. See `MIGRATION-COVERAGE.md` for all types.

Data backfill does **not** retire Base44 services. Current login, Apple purchase
verification/revocation, AI generation and push relay still use existing Base44
bridges. Their complete data is archived, without granting entitlement based on
an unchecked export, resetting quotas, or replaying provider operations. Keep
Base44 running until those services have separately been replaced and verified.

## Private files and reproducibility

Raw exports, target baseline, sealed plans, operator token and generated SQL live
under `.local/bulk-migration` (directory 0700, files 0600, gitignored). They must
never be attached to issues, commits, logs, or user-facing reports. Checked-in
evidence contains counts and hashes only.

1. Run `source-export-cli.ts` through the authenticated Base44 CLI. It reads every
   named entity twice, detects pagination/content drift, and never calls a
   repair-capable backend function. Independently read `entity-schemas` twice
   and verify that its complete remote inventory matches the export.
2. Export a current, read-only Supabase baseline using PostgreSQL JSON to retain
   timestamp precision. `buildCorePlan` plus `buildAncillaryPlan` must have zero
   blocking issues. Keep the sealed random shadow mailbox mapping when resuming.
3. `npm run migration:check` and `npm run migration:test` check the package.
   `npm run migration:rehearse` uses synthetic data; add `-- --private` for the
   private full export/baseline rehearsal. Each creates and removes its own local
   PostgreSQL database and exercises constraints, transactional application,
   identity adoption, drift, archive and rollback.
4. Run `prepare.ts` from the experiment root. It writes a fresh, sealed payload,
   a private operator job and a small initialization SQL file. Existing packet
   filenames are never overwritten. Expired source snapshots need a new export
   and a reviewed plan, not a changed timestamp.

## Exact production action requiring approval

Immediately before production execution, ask for fresh explicit approval under
the repository's `AGENTS.md` for this target and complete operation:

- Add the three private migration tables using
  `20261019102945_bulk_legacy_archive.sql`.
- Deploy the temporary `bulk-legacy-migration` Edge Function with JWT verification
  enabled, including its exact reviewed dependency closure and `deno.json`.
- Insert the one private job, upload its sealed payload, reserve immutable
  identities, provision dormant Auth accounts, then apply the reviewed data and
  archive transaction. Existing application Edge Functions are not replaced.

After approval, recheck that current source/target counts and plan dispositions
still match the reviewed operation. Never silently resolve a new conflict.
Initialize the job with `job-init.sql` (30-minute operator capability). POST the
private `job-payload.json` to `/bulk-legacy-migration/upload`, with the project's
existing anon JWT plus `x-migration-token` and `x-migration-job` headers. The
capability never belongs in a URL. Its hash, not its plaintext, is stored in SQL.

POST `{ "job_id": "<sealed job UUID>" }` to `/bulk-legacy-migration` with the same
authorization/token headers. Each request is single-flight and provisions at
most five Auth users. Retry the same job after a lost acknowledgement; do not
regenerate UUIDs, mailboxes or payload. Auth creation sends no invitation and
issues no session. Only a later verified legacy login establishes ownership.

When the endpoint returns `source_verification_required`, perform a fresh full
two-pass Base44 export and two independent schema reads. The attestation helper
must verify unchanged row contents, complete inventory and schemas, then emit
the small job-bound SQL attestation. Apply it and invoke the next step within
60 seconds. A changed source requires a refreshed reviewed plan. Source age
alone never counts as drift verification.

Run `deno run --allow-read --allow-write scripts/bulk-migration/attestation.ts
<private-job-folder> <private-fresh-folder>` after placing the fresh export,
`remote-schema-inventory.json`, and both raw `remote-entity-inventory.json` /
`remote-entity-inventory-verified.json` responses in the fresh folder. It verifies
the sealed original, every entity digest, the independent raw schema proofs,
their timestamps, and unchanged contents. Generated SQL is bound to the job,
original plan/content hashes and the literal proof time; it cannot renew stale
evidence. Require exactly one returned row when executing it.

Functional writes, provenance, archive and rollback journal commit together.
The job records aggregate results; no raw row or token is returned by HTTP.
All new migration tables have RLS enabled and no anon/authenticated privileges.

## Postflight and recovery

Read back every source disposition/row digest, all 61 mappings, SPY IDs, social
endpoints, owned-content counts and history-derived progress. Verify that no
verified links or sessions were fabricated for dormant users and no push jobs
were created. Re-export Base44 immediately after application and compare again.
The providers do not share a transaction: any intervening source change must be
reconciled before calling the migration complete. Keep the original source and
private snapshots intact.

The authenticated job is idempotent after `applied`. Expire its capability after
postflight. A temporary worker without a valid unexpired private job cannot
perform an import. Removing that temporary function is a separate exact admin
operation; do not silently replace existing application functions.

`rollbackJournal` runs only inside an explicit operator transaction and after
separate rollback approval. It compares every touched record to its recorded
post-state before changing anything. Newer user activity blocks the entire
rollback. It restores database values with full timestamp precision and respects
generated columns. The archive and immutable identity reservations remain;
dormant Auth identities are not cascade-deleted. Any later Auth cleanup must
separately verify that the account has never signed in or been verified. A
rollback must never delete a now-active user.
