# Scoped backend candidate — reliability 146

This is the historical preparation record for canonical SpyClash app
`69a0e57fa939f578082f8091`. **No production mutation was performed during this preparation.** It supersedes
the prepared authentication-only 145 candidate; neither candidate constitutes
deployment approval.

**Subsequent deployment:** fresh approval and deployment on 2026-09-06 are
recorded [separately](deployment-2026-09-06.md). The original artifact and manifest
below remain unchanged. Fresh production readback contains 169 selected files
and 192 total files: the Google callback readback has the identical `main.ts` bytes as `entry.ts`
and omits the historical, unimported `headers_test.ts`. That observed server/API
representation difference was independently audited; the original exact-path
postflight guard did not pass and was not weakened.

The initial authenticated read-only pull/schema GET completed at
**2026-09-06 15:43:20 UTC**: **17 functions, 190 runtime files, 25 entity schemas**.
CLI `whoami` succeeded before access. The bearer token was passed to the schema
GET through process stdin, never command arguments, console output or a temporary
credential file. The stored schema snapshot includes schema definitions only.

## Exact changes

The functions artifact contains **12 functions and 170 runtime files**. It changes
24 existing runtime files and adds three; it removes none. Across the full remote
inventory, the expected postflight is **17 functions / 193 runtime files**.

| Function scope | Runtime changes |
| --- | --- |
| `appleAuthBroker`, `autoRegisterUser`, `checkSubscription`, `communityAction`, `createCheckout`, `deleteAccount`, `gameRoomAction`, `generateWordPack`, `pushNotificationAction`, `stripe-entitlement-webhook`, `wordPackAction` | Replace only their identical `billing-identity-lifecycle.ts` copies with the reviewed lease-recovery implementation. |
| `appleAuthBroker` | Apply the previously reviewed Google expiry/recovery 145 changes and typed server-error classification 146 to `entry.ts`; add `google-state-recovery.ts`. |
| `googleAuthCallback` | Preserve browser response negotiation in the previously reviewed 145 `main.ts` change. |
| `generateWordPack` | Apply only today's durable operation-journal changes to `entry.ts`; add `generation-operation.ts`. The already-deployed `generation-retry-contract.ts` remains byte-identical. |
| `deleteAccount` | Apply only today's operation-entity wiring to `entry.ts` and corresponding journal cleanup in `relationship-cleanup.ts`. |
| `gameRoomAction` | Apply `game-room-followup.patch`: validated legacy expected-membership tokens; owner/recipient signal leases with immediate assertions; bounded parallel mirrors with a barrier and serialized signal fanout; update-only committed-start signals after participant leases release. Include the corresponding membership/signal helpers, `committed-game-start-repair.ts`, and terminal completion CAS reconciliation in `terminal-side-effect-dispatch.ts`. |
| `pushNotificationAction` | Add `safe-error.ts`; apply scalar, bounded logging to `entry.ts`, `error-response.ts` and two `inbox-backfill.ts` catches. No push business logic or scheduler configuration changes. |

The separate schema artifact contains **26 complete schemas**: the exact current
remote 25 plus **`AiWordPackOperation`**, whose create/read/update/delete RLS all
require the admin role. There are no existing schema definition changes or deletions.
This complete set is necessary because CLI `entities push` is authoritative.
The historical fixed-20 migration scripts are not used.

Function configuration values are preserved, including the existing
`pushNotificationAction` `drain_push_delivery_retries` automation. Pulled nested
entry paths are flattened to their basename; that path normalization is the only
configuration representation change. Existing deployed test files are preserved
byte-for-byte; newly written tests are outside both deployment artifacts.

## Provenance and excluded branch drift

The baseline comes from a new isolated pull, not a copy of the working branch.
All 11 remote lifecycle helpers match one another and revision `4b6daf7` exactly
(`6f2b9916d031bab022e17897c2cf71a401a6941302a109e42414d04b205a6218`). The fresh
`generateWordPack` and `deleteAccount` entry bytes also match that source revision,
so today's changes apply against a verified deployed basis.

Both authentication entries exactly match the baseline hashes in the reviewed
145 manifest, while the source revision matches its candidate hashes. Therefore
the combined 145/146 authentication change has an established patch basis.

The branch has unrelated entry differences in `advanceRound`,
`app-store-entitlement`, `gameRoomAction`, `pushNotificationAction`, and
`stripe-entitlement-webhook`. Only the explicitly reviewed connected game-room bundles and scalar push logging
are selected. The full game-room entry now equals the reviewed source revision
because all of its differences from this production baseline belong to those
bundles; the preparer reconstructs it through an exact patch and verifies that
equality. The remaining entry drift is preserved byte-for-byte from production. Five
unselected functions are unchanged in their entirety. Branch schemas also differ
from remote `GameRoom`, `GameRoomSignal`, and `User`; the remote definitions are
preserved exactly rather than replacing them with the branch copies.

Evidence is in `baseline-manifest.json`, `source-drift.json`,
`remote-schema-baseline.json` and `candidate-manifest.json`. The latter records
every source input, normalized function configuration, baseline/candidate file
hash and schema hash. Existing schema equality uses canonical JSON object hashes;
serialization whitespace has no effect.

## Local artifacts and verification

Temporary artifact root:

```text
/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-reliability-146-3yodigo5
```

Its `candidate-complete/functions` and `candidate-complete/schemas` directories are independent
linked projects containing only their intended resource type. `fresh` is the
unaltered pull; `baseline` is its normalized full runtime. `verification-complete` contains
test-only copies and entry aliases so tests import the actual staged code.
`complete-patch-reconstruction` demonstrates exact patch application to the
complete baseline, with no fuzz. Temporary files may eventually be removed by
macOS; committed manifests, schema baseline, preparation scripts and `runtime.patch`
remain the review record.

The persisted patch SHA-256 is:

```text
bf66236735fdf3500dcdc0fb29ffb6b5d131a9c7334c57b53713488af6d83382
```

Verification completed against the staged runtime:

- **The full 12-function suite passed: 956 tests / 13 handler steps, 0 failed**
  (`complete-full-tests.log`). This includes the regression where guest departure
  wins the first completion CAS, after which completion preserves that departure
  without executing the side effect again.
- All **12 exact deployment entry points** passed Deno type checking
  (`complete-entry-typecheck.log`).
- Exact patch reconstruction passed the full expected postflight guard:
  **17 functions / 193 files**, including all five unchanged functions.
- **15 negative guards passed**: altered/missing/extra runtime, wrong binding,
  automation/configuration drift, extra function/resource, symlink, altered or
  missing existing schema, extra schema, weaker ledger RLS, unselected production
  function drift, later source edits, and patch corruption all stop verification.
- **Nine additional profile-fence/barrier fault tests passed.** The persistent
  `profile-fence-candidate_test.ts` fixture executes staged profile code and imports
  its exact runtime helpers; set
  `SPYCLASH_CANDIDATE_FUNCTIONS_ROOT` to `candidate-complete/functions` when running
  it. Its final additional fault-test result is recorded in `verification-results.json`.
- Independent review confirmed the connected entry hunks, unchanged configurations,
  five untouched functions and exact 25+1 schema boundary.

The test-only verification tree contains all unchanged remote helper dependencies
and the exact 26 candidate schema objects, with entry/filename aliases required by
historical test imports. Every test directory for the 12 selected functions ran;
no failing test was removed or weakened. Earlier intermediate candidates exposed
five genuine code/branch-contract gaps after missing test fixtures were restored.
The final candidate includes the connected start-repair and terminal-completion
fixes, plus the explicitly requested profile concurrency improvement, and the
complete suite is now green. Prior logs remain available as provenance; their
intermediate results do not describe the final artifact.

## Preflight and authorized-operation procedure

The scripts here perform only local preparation/verification or read-only remote
acquisition. They do not deploy. Before a future production operation, obtain fresh
approval for **adding this one schema and deploying these exact 12 functions**.
No approval for an earlier game-room/generation change or build authorizes this
candidate.

1. Run `fetch-production-baseline.py --project-root <repository> --output-root
   <new-isolated-directory>`. It rechecks CLI authentication, binds the canonical
   app, pulls all functions, and GETs all schemas without exposing credentials.
2. Run `verify-candidate.py functions --mode baseline --root <new-directory>/fresh`
   and `verify-candidate.py schemas --mode baseline --schema-response
   <new-directory>/remote-schemas.json`. Stop on any remote drift.
3. Verify the exact artifacts with `verify-candidate.py functions --mode candidate
   --root <artifact-root>/candidate-complete/functions --source-root <repository>` and
   `verify-candidate.py schemas --mode candidate --root
   <artifact-root>/candidate-complete/schemas`. Stop on changed source, patch, binding,
   configuration, resource inventory or hash.
4. Only after explicit production approval, run `npx --no-install base44 entities
   push` from `candidate-complete/schemas`. Re-fetch and verify schema mode `candidate`
   before deploying dependent runtime; verify functions still match `baseline`.
5. From `candidate-complete/functions`, deploy only the following named functions with
   `npx --no-install base44 functions deploy` followed by these arguments:

   ```text
   appleAuthBroker autoRegisterUser checkSubscription communityAction createCheckout deleteAccount gameRoomAction generateWordPack googleAuthCallback pushNotificationAction stripe-entitlement-webhook wordPackAction
   ```

6. Freshly fetch all functions and schemas into another new directory. Verify
   functions mode `postflight` and schemas mode `postflight`. This proves all
   targeted bytes and the five unselected functions, plus the exact 26 schemas.
   Retain command outcomes and snapshot evidence. Do not use generic `base44
   deploy`, force/prune, old migration scripts, or the working repository as the
   deploy directory.

Structural postflight verification does not prove a new Google/Apple login,
two-device game, or recovery from a real interrupted provider request. Those
remain separate acceptance evidence. If the temporary artifacts are missing,
reconstruct locally using `prepare-candidate.py` against a normalized baseline
matching this manifest, then rerun every guard and affected test before promotion.
