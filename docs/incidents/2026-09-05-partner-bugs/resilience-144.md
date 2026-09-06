# Conflict recovery and contention reduction: Build 144

Status: **approved server changes deployed and pulled source verified** on September 6 at approximately 07:47:43 UTC. See the [deployment record](deployment-resilience-2026-09-06.md). The earlier [September 6 hotfix](deployment-2026-09-06.md) remains in place. iOS version is 1.0.1 / 144 in both project files; the client changes have not been delivered to phones. Live-game and process-kill acceptance remain open. This record does not authorize another deployment.

## Intended behavior

Ordinary gameplay should recover from short contention without duplicate actions. A stale exit must never close a replacement membership. Automatic AI retries must not repeat potentially charged/provider work. Necessary ownership, deletion and revision checks remain enforced.

The observed September 6 post-deployment traffic includes successful generation at 07:11:13 UTC and a separate `close_room` / `room_exit_membership_conflict` at 07:10:37 UTC. HTTP 409 alone is not an incident classification; record the function, action and typed conflict code. No account or room identifiers are included here.

## Changes

- Room participant lease validation and exact-owner cleanup use waves of at most four independent operations. Acquisition stays ordered. Every started operation settles before the response, and cleanup still attempts all participant releases when one fails. This reduces serial round trips without weakening account deletion coordination.
- All existing signal-row writes, including the separate close-completion receipt, now use atomic comparison with the observed row. Deleted rows are not recreated by a delayed update; lost responses are reconciled with at most three attempts. Old signals cannot downgrade a newer revision, closure or confirmed Activity end enqueue receipt. Participant leases remain required during this stage: removing them while older deployed handlers still use unconditional updates could allow a stale signal to overwrite a newer one.
- Completed or terminal room-exit cleanup is remembered separately from the local room-dismissal fence. The receipt belongs to the exact account, room, membership and exit intent, preventing another foreground/relaunch from resending an obsolete close. Cancellation and ambiguous failures do not count as completion.
- Authentication failures also remain pending: a 401 stops the current attempt but allows cleanup after a renewed login. This includes the former host's leave fallback. An independent review caught this distinction before handoff; two regression tests cover it.
- Generation retries require an explicit server contract proving that the current attempt has not started an entity write or AI call. The client retains one immutable request ID and payload, caps retries, and stops on cancellation/account change. Legacy metadata, transport failures and possible post-effect failures cannot authorize automatic replay.

## Why the ten-minute lease is not simply shortened

The current lease must outlast the maximum lifetime of a backend invocation. A process can be suspended immediately after checking ownership and resume later. Shortening the lease or clearing every active lease during deploy can let an old writer persist after a new writer or account deletion has started. The existing datastore operations do not provide a transaction spanning the lifecycle row and every protected entity write.

Awaited cleanup covers normal completion and failures whose cleanup still runs. It cannot run after an actual process termination. Therefore this patch does not establish automatic recovery from every hard kill, nor does it promise that all legitimate conflicts disappear.

## Conditions for a later architecture change

1. Remove account leases from update-only room signals only after every writer uses an atomic row comparison and the old runtime has drained. Missing/deleted rows must never be recreated by this path; duplicate rows must fail closed.
2. Separate resource-level writes from account deletion coordination only with an explicit fencing/transaction protocol. Each late write must be rejected atomically at its own persistence boundary; a preceding read of the lease alone is insufficient.
3. For AI recovery across process crashes, persist an operation ledger before effects. It must distinguish reserved/running, committed result and ambiguous provider outcome. Result-only idempotency cannot prove whether an earlier crashed attempt called the provider or reserved quota.
4. Exercise an active multiplayer session across deployment and inject lost responses, delayed writes, lease-release failure and process termination. Verify membership, saved results, quota and duplicate effects, rather than only HTTP status.

## Verification

- Debug Simulator build/install/launch succeeded on iPhone 17. Full final XCTest: **456 passed, 0 failed, 0 skipped**. Tests include immutable generation payloads, strict retry metadata, cancellation/account switch including switch-back, persisted exit receipts, and authentication recovery.
- Final result bundle: `/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-09-06T07-37-07-804Z_pid23192_7ea6c5cb.xcresult`.
- Relevant function suites: **673 passed, 0 failed** (`gameRoomAction` 398, `generateWordPack` 85, `pushNotificationAction` 168, `wordPackAction` 22).
- The expanded run including historical cutover/schema checks finished **734 passed, 5 failed**. All five failures were reproduced on an isolated `git archive` of pre-change `a0e7b3a`; their assertion blocks matched after path normalization. They concern old entity inventory/schema counts and cutover digests, not these runtime changes. See [baseline comparison](resilience-144-baseline-test-comparison.json). The whole repository is therefore not reported as entirely green.
- Production-based isolated candidate: **139 passed, 0 failed**, and both exact deployed entry points type-check. Local integration entry points also type-check. Runtime isolation, client entity boundaries, entity RLS completeness and diff checks pass.
- A fresh server pull matched the reviewed **61 baseline runtime files and two configurations**. Candidate verification matched **62 runtime files and two configurations**. Patch reconstruction passes; a negative test rejects runtime hash drift.
- Initial test setup issues were resolved: the Swift test closure needed explicit `@MainActor`; broad local cutover tests needed filesystem/process permissions for their temporary fake-CLI fixtures. The final counts above are after those corrections.

No physical device, App Store release, process-kill acceptance, paid AI call or production gameplay mutation was performed for these checks. The concurrency tests use injected stores/providers. They do not establish exactly-once provider work across a process crash.

## Exact server candidate

Canonical app: `69a0e57fa939f578082f8091`. Completed operation: `npx base44 functions deploy gameRoomAction generateWordPack` from the verified isolated deploy root below, after fresh explicit approval and a repeated baseline check. No schema, secret, site, automation, payment or additional-function change was included.

| Function | Runtime changes |
| --- | --- |
| `gameRoomAction` | `entry.ts`, `game-room-signal.ts`, `room-write-lifecycle.ts` |
| `generateWordPack` | `entry.ts`, new `generation-retry-contract.ts` |

The candidate intentionally takes the complete reviewed room lifecycle helper: in addition to bounded parallel validation/cleanup, production's six pre-action acquisition attempts become eight (2.575 seconds total backoff), and release-error logging is scalar-safe. The action callback is still never replayed. These two previously local improvements are now explicitly in scope. Shared billing lifecycle copies and the ten-minute TTL are unchanged. Other broader branch differences listed in [the previous scope](backend-deployment-scope.md#broader-branch-differences-deliberately-excluded) remain excluded.

- Deploy root: `/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-resilience-144-8uyzns5h/deploy`.
- Initial baseline recheck: sibling `fresh/`; isolated tests: sibling `verification/`; results: `candidate-tests.log` and `candidate-check.log` in the parent directory. The final approved run's fresh preflight and postflight are recorded in the deployment record.
- Persisted [runtime patch](resilience-144-runtime.patch), [hash manifest](resilience-144-runtime-manifest.json), and [read-only guard](verify-resilience-runtime.py) identify the exact candidate even if temporary staging expires.
- Guard usage: `python3 verify-resilience-runtime.py <fresh-pull-root> --mode baseline` before deployment and `python3 verify-resilience-runtime.py <candidate-or-postflight-root> --mode candidate` for staging and pulled deployed code. Only the function entry path is normalized for configuration comparison.
- To reconstruct, flatten both functions from a fresh pull that passes the baseline guard, preserve their configuration except normalized `entry: "entry.ts"`, then apply the committed runtime patch. The candidate guard and isolated tests must pass before deployment.

Updating these two server functions does not deliver the iOS cleanup/retry changes to installed phones; those require Build 144. Older clients retain their existing behavior and safely ignore the new error metadata.
