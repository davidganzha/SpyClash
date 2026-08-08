# SpyClash Base44 security cutover

This document describes the future Production cutover for Base44 app
`69a0e57fa939f578082f8091`. It is not authorization to run any Production
command. Obtain a fresh, explicit confirmation immediately before every
Production mutation and stop before the next numbered mutation if that
confirmation has not been given.

Never use `base44 eject` to inspect or back up this existing app. Eject creates
a separate Base44 application namespace and can immediately deploy a stale
copy. Use the app-ID-pinned `functions pull` backup flow below instead.

The canonical local set contains 20 entities. Base44's built-in `User` entity
keeps its platform-owned self-read/self-update security. The other 19 entities
declare complete RLS. Seventeen are service-role/admin-only; `GameHistory` and
`MembershipGrant` additionally allow an authenticated user to read only their
own rows. `GameHistory.player_user_id` and `match_id` remain visible only after
that row-level read succeeds, while their field-level writes are admin-only;
this lets clients load stable ownership without making either field writable.

The read-only Production audit on 26 July 2026 found 17 entities. Production
was missing `AppleSignInCredential`, `AiWordPackCacheVariant`, and
`AiWordPackRequestResult`; `AiGenerationQuota`, `GameRoom`, `GameHistory`, and
`WordPack` had no entity-level RLS. Production also lacked the canonical stable
owner/match/event, pause, localized Live Activity, and durable force-end fields.
Treat this only as a timestamped baseline and refetch immediately before the
cutover.

## Read-only preflight

Run from the repository root. None of these commands may be replaced with
`base44 deploy`, a nameless `functions deploy`, `--force`, or a schema push.

```bash
npx --yes base44@0.1.4 whoami
scripts/sync-base44-billing-lifecycle.sh
scripts/sync-base44-billing-lifecycle.sh --check
scripts/sync-base44-apple-coordination.sh
scripts/sync-base44-apple-coordination.sh --check
scripts/check-base44-release-secrets.sh
scripts/check-base44-entity-rls.sh
scripts/check-base44-function-bundles.sh
scripts/check-client-entity-boundaries.sh
TMPDIR=/tmp npx --yes deno test --allow-env --allow-net --allow-read \
  --allow-run --allow-write=/tmp \
  $(find base44/functions -name '*_test.ts' -print | sort) \
  base44/tests/*.ts
scripts/push-base44-additive-schema.sh
scripts/backup-base44-functions.sh
```

Inspect the additive manifest. It must preserve every live entity, add only
canonical missing entities/optional fields, delete none, and close direct
create/update/delete on custom entities. Before any guarded function deploy,
the stage must also add `GameHistory.match_type`/`ranked`; add the missing
`User.rating`, `spy_id`, and SpyCard fields; extend `User.language` with `es`;
and put admin-only field write rules on the rating/statistics/AI usage/Spy ID
mirrors while preserving Base44's built-in User row security. At the current
audited boundary the canonical-only Production entities are
`AppleSignInCredential`, `AiWordPackCacheVariant`, and
`AiWordPackRequestResult`; refetch instead of assuming that list is still
current. The prepared manifest must name every entity addition/deletion and
every property/RLS delta. Preparation fails before confirmation if the live
name set contains anything outside the exact reviewed 20-entity canonical
universe or if the target does not contain exactly 19 custom entities with
admin-only direct create/update/delete.

## Production mutation order

Every mutating mode below (`--push`, `--set`, `--deploy`, or `--apply`)
acquires `.base44-cutover/.production-mutation.lock` before its step-specific
lock. Read-only prepare/check modes do not acquire the shared lock. This fixed
global-then-local order prevents schema, function, secret, and backfill
wrappers from racing one another. `HUP`, `INT`, and `TERM` exit immediately and
then release owned locks; `SIGKILL` can leave a fail-closed stale lock. Never
delete a stale lock speculatively: first inspect its `owner` action/PID, prove
that PID is no longer running, verify the path is the regular owned directory
inside this repository, and only then remove its owner file and empty
directory. No script automatically reclaims the shared lock.

1. Push the freshly prepared additive schema with the exact app-id and the
   inspected additive-plan digest guards. This
   begins a short write-maintenance window while preserving existing read
   rules. It must precede any function that expects the new entities or fields,
   including Community profile/Spy ID writers and ranked GameHistory writes.

   ```bash
   ADDITIVE_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/additive-schema/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_ADDITIVE_PLAN_DIGEST="$ADDITIVE_PLAN_DIGEST" \
     scripts/push-base44-additive-schema.sh --push
   ```
2. Run `scripts/ensure-base44-pseudonym-secret.sh`. The current Production
   name-only check reports `SPYCLASH_PSEUDONYM_KEY` already configured, so this
   step is a no-op: never rotate the existing value. If a future fresh audit
   reports it missing, setting it is its own exact-confirmation action using
   the reviewed app id and the exact prepared plan digest:

   ```bash
   scripts/ensure-base44-pseudonym-secret.sh
   PSEUDONYM_SECRET_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/pseudonym-secret/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST="$PSEUDONYM_SECRET_PLAN_DIGEST" \
     scripts/ensure-base44-pseudonym-secret.sh --set
   ```

   The generated value is never printed or stored in the manifest. The script
   performs a just-in-time name-only inventory check and refuses to rotate a
   value that appears after preparation. Before the sole `secrets set`, it
   persists a private, attempt-ID-bound marker; a crash or ambiguous response
   cannot be mistaken for an ordinary existing-secret no-op on the next run.
3. Deploy the retryable `deleteAccount` maintenance guard. Deletion must remain
   unavailable until the final implementation is deployed. The read-only
   preparation records the exact 16-function Production inventory and the
   current/desired `deleteAccount` semantic digests:

   ```bash
   scripts/deploy-base44-delete-maintenance-guard.sh
   DELETE_GUARD_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/delete-maintenance-guard/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_DELETE_GUARD_PLAN_DIGEST="$DELETE_GUARD_PLAN_DIGEST" \
     scripts/deploy-base44-delete-maintenance-guard.sh --deploy
   ```
4. Deploy this explicit coordinated function set together, excluding the final
   `deleteAccount` implementation. Prepare the read-only deployment manifest
   only after steps 1–3 are live. The script re-runs the local tests and secret
   checks, proves the 20-entity additive prerequisite, pulls the current remote
   functions, verifies the maintenance `deleteAccount` guard, and binds the
   exact local function tree to both the Production schema and remote-function
   digests:

   ```bash
   scripts/deploy-base44-coordinated-functions.sh
   COORDINATED_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/coordinated-functions/manifest.json)
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_4_DEPLOY_15 \
   BASE44_CONFIRM_COORDINATED_FUNCTION_PLAN_DIGEST="$COORDINATED_PLAN_DIGEST" \
     scripts/deploy-base44-coordinated-functions.sh --deploy
   ```

   The guarded command names all 15 functions explicitly, never uses
   `--force`, and pulls them again after deployment to verify the normalized
   bundle digest. It also reruns the complete read-only schema classifier after
   deployment and cannot report success unless both schema digests still match
   the immediately pre-deploy boundary. A private, atomically installed and
   synced attempt marker is durable before the first function deployment; any
   helper/hash/postflight failure remains an explicit failed or ambiguous
   attempt rather than a false success:

   ```text
   advanceRound
   app-store-entitlement
   appleAuthBroker
   appleAuthCallback
   autoRegisterUser
   checkSubscription
   communityAction
   createCheckout
   gameRoomAction
   generateWordPack
   googleAuthCallback
   mobileAuthCallback
   pushNotificationAction
   stripe-entitlement-webhook
   wordPackAction
   ```

5. Publish the validated public release-site commit. This release bundle ships
   only Landing, Privacy, Terms, and Support; it imports no Base44 client and
   redirects every legacy game, authentication, and pricing route to Landing.
   The interactive site remains preserved in source control for a later fully
   mediated cutover. Do not publish until the monitored support email is baked
   into the candidate and the guarded site manifest is inspected. From the
   clean `davidganzha/appstore-site-24` web worktree, run the default preparation
   first; it is expected to stop before authentication or build while the
   `spyclash-support-email` meta value is empty:

   ```bash
   ./scripts/deploy-release-site.sh
   # After baking and committing the monitored email, rerun the command above.
   RELEASE_SITE_PLAN_DIGEST=$(sed -n \
     's/^PLAN_SHA256=//p' .base44-cutover/release-site-plan.manifest)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_5_PUBLIC_SITE \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_RELEASE_SITE_PLAN_DIGEST="$RELEASE_SITE_PLAN_DIGEST" \
     ./scripts/deploy-release-site.sh --deploy
   ```

   The deployment command is intentionally site-only. It rebuilds and binds
   every `dist` byte to the approved commit and support email, publishes no
   entities/functions/secrets, and verifies all four live routes plus hashed
   assets, icons, and the absence of the retired public labels and Google
   Analytics markers.
6. Prepare `scripts/push-base44-final-schema.sh`, inspect its fresh manifest
   and every diff, then push only with both the exact app id and the inspected
   plan digest. It must report 20 live and 20 canonical entities, zero adds,
   zero deletes, and only the reviewed policy/schema changes. Re-run the
   read-only preparation afterward; it must report zero changes.

   Before the authoritative push the wrapper snapshots the complete reviewed
   stage (`manifest.json`, `base44/`, and `diff/`) into private
   content-addressed evidence and copies that snapshot into the attempt
   directory. A later prepare therefore cannot erase the exact pre-change
   payload or diff needed for forensic recovery.

   ```bash
   scripts/push-base44-final-schema.sh
   FINAL_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/final-schema/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_FINAL_PLAN_DIGEST="$FINAL_PLAN_DIGEST" \
     scripts/push-base44-final-schema.sh --push
   ```
7. Run the stable-owner backfill dry-run. Apply it only when every unresolved
   and mismatch count is zero. Re-run dry-run after apply; it must report zero
   room and word-pack updates. The data migration writes only
   `GameRoom.participant_user_ids`, `players[].user_id`, and
   `WordPack.owner_user_id`; coordination also acquires and releases the normal
   `BillingIdentityLifecycle` writer leases for every affected user. It treats
   `updated_date` only as a re-read
   precondition because Base44 does not support it as a reliable GameRoom
   `updateMany` predicate; each stable-id update is instead serialized by the
   same per-user lifecycle leases as the Production room and word-pack writers,
   then re-read and verified.

   ```bash
   scripts/run-base44-sensitive-owner-backfill.sh \
     --app-id 69a0e57fa939f578082f8091
   OWNER_BACKFILL_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/sensitive-owner-backfill/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST="$OWNER_BACKFILL_PLAN_DIGEST" \
     scripts/run-base44-sensitive-owner-backfill.sh \
       --app-id 69a0e57fa939f578082f8091 --apply
   ```

   Two consecutive snapshots must match before apply and again afterward.
   Successful apply evidence is retained separately in
   `.base44-cutover/sensitive-owner-backfill/completion.json`; later read-only
   runs cannot overwrite it. The wrapper executes only the byte-exact,
   content-addressed source set referenced by
   `.base44-cutover/sensitive-owner-backfill/reviewed-inputs-current.json`,
   holds one operation lock, and rehashes the repository, reviewed stage, and
   private execution copy immediately before apply. It atomically persists
   `last-attempt.json` before the first possible write; any pending, failed, or
   mismatched attempt blocks Step 8. The persisted plan contains record ids,
   `updated_date` read-preconditions, user-id projections, lifecycle-source
   hashes, and the exact reviewed mutation scope, but no email fields.
8. Deploy the final coordinated `deleteAccount` implementation only after the
   guard proves that Production still has the reviewed maintenance handler,
   the other 15 functions exactly match the coordinated release, the final
   schema has zero drift, the successful Step 7 completion evidence is intact,
   its content-addressed input stage and completed attempt marker still match,
   and a fresh owner dry-run remains zero-update:

   ```bash
   scripts/deploy-base44-final-delete-account.sh
   FINAL_DELETE_PLAN_DIGEST=$(jq -er '.plan_digest' \
     .base44-cutover/final-delete-account/manifest.json)
   BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT \
   BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
   BASE44_CONFIRM_FINAL_DELETE_ACCOUNT_PLAN_DIGEST="$FINAL_DELETE_PLAN_DIGEST" \
     scripts/deploy-base44-final-delete-account.sh --deploy
   ```

   The only mutating CLI call names `deleteAccount` explicitly. The script
   always pulls all 16 functions and repeats schema/backfill checks afterward,
   even when the deploy command reports an error, so any partial or ambiguous
   state is recorded for a forward repair.
9. Run Production smoke tests with two ordinary users, one admin/operator, and
   one disposable Sign in with Apple account. Prove direct CRUD denial,
   owner-only history/grant reads, mediated room and Community actions,
   moderation retention, push registration/delivery, Live Activity
   start/update/end, and complete disposable account deletion plus Apple
   credential revocation.

## Stop and rollback rules

- Before the additive push, abort without mutation if entity names, schema
  fields, secrets, function inventory, or manifests differ from the inspected
  plan.
- After the additive push, do not restore client-writable schema rules. Leave
  the write-maintenance boundary in place and correct the coordinated release
  forward.
- After the deletion guard is deployed, keep it deployed through any failure.
  Do not restore the old deletion function while lifecycle entities or writers
  are mixed-version.
- A function backup is diagnostic evidence, not an automatic rollback bundle.
  Never restore a subset that crosses the shared deletion lifecycle. Before
  final RLS, a rollback is allowed only after proving the entire old function
  set is compatible with the additive schema; after final RLS, use a forward
  fix only.
- Do not roll the mediated site back to a direct-entity writer after write
  lockdown or final RLS.
- The owner backfill is lifecycle-serialized and idempotent. On a partial apply
  or conflict, stop writers, re-run dry-run, repair the ambiguous identity
  mapping, and continue forward. Do not erase stable owner ids to recreate
  legacy email ownership.
- Never roll back `AppleSignInCredential`, lifecycle, moderation, push-token,
  or Live Activity entities by deleting them. Preserve encrypted credentials,
  deletion tombstones, moderation evidence, and delivery state for a forward
  repair.
- Any failed direct-access denial, cross-account read/write, deletion race,
  missing APNs event, or unresolved backfill count blocks the App Store build
  upload and review submission.
