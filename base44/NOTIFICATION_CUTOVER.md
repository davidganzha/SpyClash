# Notification inbox Base44 cutover

This runbook is separate from the historical 20-entity / 16-function security
cutover. The older scripts and their evidence remain immutable historical
records. Neither command below changes the site, data, secrets, authentication,
App Store state, or any other Base44 application.

The reviewed application is fixed to `69a0e57fa939f578082f8091`.

## Step 0: restore the approved final 20-entity boundary

The notification prepare found that the current 20-entity Production schema no
longer matches the successful Step 6 postflight from 2026-07-26. Do not weaken
Step A to accept that drift. First reproduce the exact approved final schema
with the dedicated repair command:

```sh
./scripts/repair-base44-final-schema-before-notifications.sh
```

This default invocation is read-only. It requires all of the following before
it will even create a local plan:

- app id `69a0e57fa939f578082f8091`;
- exact current drifted 20-entity digest
  `038cd5a3f0989826ac92580272da099979549b15cdfa70353feafed3c20525fb`;
- the preserved successful Step 6 plan
  `a55997ac76faa1c166fc3d68b4df644a961d4f41c04ad9cfd16ef345e4b4127a`;
- exact approved target digest
  `f09988b0e0b5c5e93a55c4738e47ba20b160bd536ee0cacd65337fa05fd674af`.

Inspect the generated evidence:

```sh
jq . .base44-cutover/notification-step-0-schema-repair/manifest.json
jq . .base44-cutover/notification-step-0-schema-repair/schema-delta.json
```

The repair changes exactly eight entities (`AiGenerationQuota`, `Entitlement`,
`GameHistory`, `GameRoom`, `LiveActivityRegistration`, `MembershipGrant`,
`User`, and `WordPack`), restores 20 missing properties, restores the reviewed
RLS on four custom entities, removes zero fields, and adds or deletes zero
entities. Required lists do not change. The complete target is byte-normalized
against the preserved approved Step 6 stage; this is not a merge with an
unreviewed schema.

A future, separately authorized Production repair requires the exact freshly
prepared digest in the command and confirmation environment:

```sh
PLAN_DIGEST=$(jq -er .plan_digest \
  .base44-cutover/notification-step-0-schema-repair/manifest.json)
BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
BASE44_CONFIRM_ACTION=SPYCLASH_NOTIFICATION_STEP_0_SCHEMA_REPAIR \
BASE44_CONFIRM_NOTIFICATION_SCHEMA_REPAIR_PLAN_DIGEST="$PLAN_DIGEST" \
./scripts/repair-base44-final-schema-before-notifications.sh \
  --deploy --plan-digest "$PLAN_DIGEST"
```

The deploy path holds the shared Production lock, reproduces the fixed plan,
performs a fresh JIT schema fetch, writes a durable attempt marker before the
CLI boundary, and always records postflight. Do not run Step A unless Step 0's
fresh postflight exactly matches the approved final digest and restores the
19-custom-entity admin-write boundary.

## Step A: additive notification schema

The default invocation is a read-only Production inspection. It fetches the live
schema, requires the exact 20-entity baseline, builds a complete 22-entity
authoritative candidate locally, records exact deltas and hashes, and makes no
remote change:

```sh
./scripts/cutover-base44-notification-schema.sh
```

Inspect the resulting files:

```sh
jq . .base44-cutover/notification-step-a-schema/manifest.json
jq . .base44-cutover/notification-step-a-schema/schema-delta.json
```

The only allowed delta is:

- add `NotificationAnnouncement` and `NotificationReadReceipt`;
- add `announcements_enabled` to `PushDeviceRegistration`;
- append `global_announcement` / `notification_announcement` and add the 14
  reviewed optional inbox fields to `PushNotificationEvent`;
- add the optional account-scoped `radar_invite_policy` field to `User`;
- delete no entity or field, and change no existing RLS or required list.

`--deploy` is intentionally unusable without all four independent gates: the
flag, the exact command-line digest, the same digest in the confirmation
environment, and the exact app/action confirmation. A future, separately
authorized Production execution would have this shape (do not reuse a stale
digest):

```sh
PLAN_DIGEST=$(jq -er .plan_digest \
  .base44-cutover/notification-step-a-schema/manifest.json)
BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
BASE44_CONFIRM_ACTION=SPYCLASH_NOTIFICATION_STEP_A_SCHEMA \
BASE44_CONFIRM_NOTIFICATION_SCHEMA_PLAN_DIGEST="$PLAN_DIGEST" \
./scripts/cutover-base44-notification-schema.sh \
  --deploy --plan-digest "$PLAN_DIGEST"
```

The script re-fetches Production immediately before mutation, hashes the fixed
stage and local canonical inputs again, writes a durable attempt marker, and
always persists a fresh postflight after the CLI returns.

## Step B: coordinated function deployment

Step B cannot be prepared until Step A has a successful, exact postflight and
the fresh Production schema still matches that 22-entity digest. Its default
invocation is also read-only:

```sh
./scripts/cutover-base44-notification-functions.sh
```

Inspect:

```sh
jq . .base44-cutover/notification-step-b-functions/manifest.json
jq . .base44-cutover/notification-step-b-functions/function-delta.json
```

The exact function delta is one addition (`notificationAction`), four updates
(`communityAction`, `gameRoomAction`, `deleteAccount`, and
`pushNotificationAction`), zero deletions, and twelve untouched live source
digests. Deployment order is deliberate: `notificationAction`,
`communityAction`, `gameRoomAction`, `deleteAccount`, then
`pushNotificationAction`. The last function activates the reviewed bounded
retry drain (`limit: 64`). The original cutover used Base44 Production's
minimum five-minute interval; the current reviewed schedule runs every fifteen
minutes. This cutover does not create or publish a global announcement.

A future, separately authorized Production execution would have this shape:

```sh
PLAN_DIGEST=$(jq -er .plan_digest \
  .base44-cutover/notification-step-b-functions/manifest.json)
BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
BASE44_CONFIRM_ACTION=SPYCLASH_NOTIFICATION_STEP_B_FUNCTIONS \
BASE44_CONFIRM_NOTIFICATION_FUNCTION_PLAN_DIGEST="$PLAN_DIGEST" \
./scripts/cutover-base44-notification-functions.sh \
  --deploy --plan-digest "$PLAN_DIGEST"
```

Step B performs a final schema fetch and full function pull before deployment.
Its postflight requires an exact 17-function inventory, exact reviewed hashes
for all five targets, unchanged before/after hashes for all twelve non-targets,
and an unchanged Step A schema digest.

### Partial Step B recovery (28 July 2026)

The authorized Step B attempt for plan
`4896ee8d3d852edd634f336da7ca919f6e3d627691bcf16aef5d6ce3359ac5c5`
stopped after Base44 Production rejected the one-minute schedule in
`pushNotificationAction`. Production now contains the reviewed Step B versions
of `notificationAction`, `communityAction`, `gameRoomAction`, and
`deleteAccount`; `pushNotificationAction` remains at its pre-Step-B version.
The old five-function plan must not be rerun against this changed baseline.

Prepare the dedicated push-only recovery plan with the read-only default:

```sh
./scripts/recover-base44-notification-push-function.sh
```

The recovery plan requires exactly 17 live functions and the exact 22-entity
Step A schema. Its only allowed delta is `pushNotificationAction`; it preserves
the other 16 function trees byte-for-byte. The retry drain runs every fifteen
minutes with a bounded batch of 64; Base44's minimum accepted interval remains
five minutes. A future, separately authorized recovery has this shape (always
use the freshly prepared digest):

```sh
PLAN_DIGEST=$(jq -er .plan_digest \
  .base44-cutover/notification-step-b-push-recovery/latest-plan.json)
BASE44_CONFIRM_APP_ID=69a0e57fa939f578082f8091 \
BASE44_CONFIRM_ACTION=SPYCLASH_NOTIFICATION_STEP_B_PUSH_RECOVERY \
BASE44_CONFIRM_NOTIFICATION_PUSH_RECOVERY_PLAN_DIGEST="$PLAN_DIGEST" \
./scripts/recover-base44-notification-push-function.sh \
  --deploy --plan-digest "$PLAN_DIGEST"
```

Immediately before mutation, the recovery script re-pulls Production, verifies
the reviewed baseline and schema, copies the reviewed payload into a fresh
private directory, and re-hashes that copy. Postflight requires the target to
match, all 16 non-target function trees to remain byte-identical, and the schema
digest to remain unchanged.

## Evidence and recovery boundary

All three steps use the shared `.base44-cutover/.production-mutation.lock`, separate
signal traps, private fixed stages, and atomic durable evidence below
`.base44-cutover/evidence/`. A CLI error is not rolled back automatically. The
fresh postflight is the authority; any partial or ambiguous state requires a new
read-only plan, a new digest, and a new explicit Production authorization.
