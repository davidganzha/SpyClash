# Incident-only backend candidate

Status: prepared and locally verified; **not deployed**. Any production action still needs fresh explicit approval in the current chat.

Target: canonical SpyClash Base44 app `69a0e57fa939f578082f8091`. The proposed operation deploys exactly `gameRoomAction` and `pushNotificationAction` from the isolated candidate below. It changes five runtime files, with no entity/schema, secret, site, payment, or automation changes. The existing push drain remains every 15 minutes.

The production evidence identifies a shared account writer lease stranded after a 600 ms response timeout. The server reported in-flight work at response, and the lease remained until its ten-minute expiry. Subsequent lobby updates, joining, generation and pack writes collided with that lease. This document deliberately omits private account and room identifiers.

## Exact runtime changes

| Function | Runtime files changed | Result |
| --- | --- | --- |
| `gameRoomAction` | `entry.ts`, `post-lease-signal.ts`, `game-room-signal.ts` | The time budget stops new secondary work. The response awaits started signal writes and account-lease cleanup. Duplicate signal updates settle together before lease cleanup. Applies to lobby and finished-game signals. |
| `pushNotificationAction` | `entry.ts`, `bounded-work.ts` | Queued Live Activity delivery awaits started workers. Parallel worker failures stop new items and await siblings before returning. |

The candidate contains 48 runtime files in `gameRoomAction` and 27 in `pushNotificationAction`: five are patched and the other 70 are byte-identical to the pulled production snapshot. Function configurations preserve the deployed settings; only the local source entry path is normalized to `entry.ts` for staging.

The patch does not replay a committed room/generation/pack action, shorten the ten-minute crash protection, or weaken account-deletion coordination. Cleanup attempts are awaited; an actual storage failure can still prevent release and fall back to the existing expiry. An already-started slow storage request can extend the response beyond the work budget.

## Candidate and verification

- Prepared deploy root: `/tmp/spyclash-backend-hotfix-143-iBQKJC/deploy`.
- Source snapshot: `/tmp/spyclash-runtime-409-Mky03I`.
- Fresh production recheck: `/tmp/spyclash-backend-hotfix-143-iBQKJC/fresh`; all 75 source files and both configurations matched the snapshot.
- Isolated runtime tests: `/tmp/spyclash-backend-hotfix-143-iBQKJC/verification`; **50 passed, 0 failed**, including the actual production lifecycle/generation/word-pack helpers. A slow signal test verifies that subsequent join, generation and pack save can acquire the account normally.
- Candidate entry points and changed helpers passed `deno check`.
- Separate integrated source validation: **647 relevant backend tests passed**. These are local checks; they do not establish post-deployment live acceptance.

The persisted patch is `backend-incident-only.patch`. The manifest records both baseline and candidate SHA-256 for every runtime file, plus normalized function configuration hashes. Tests are stored only in the separate verification directory and are not in the deployment source inventory.

## Deployment preparation and drift guard

1. Immediately before any approved deployment, authenticate with `npx base44 whoami` and pull these two functions into a **new empty directory** linked to the canonical app. Do not pull over either the integration tree or the candidate.
2. Run `python3 verify-backend-runtime.py <fresh-pull-root> --mode baseline`. Stop on any source/configuration/inventory difference; rebuild and review the patch against the new production source before seeking approval again.
3. Run `python3 verify-backend-runtime.py /tmp/spyclash-backend-hotfix-143-iBQKJC/deploy --mode candidate`. This must verify 75 runtime files and 2 configurations. Never deploy the broader integration worktree for this incident-only scope.
4. State the exact app and the two-function operation and obtain fresh explicit production approval. Only then, from the verified candidate root, run the targeted CLI operation `npx base44 functions deploy gameRoomAction pushNotificationAction`. Do not use a broad app deploy or `--force`.
5. Pull both functions again into another empty directory and compare every returned runtime file against the manifest's candidate hashes. Pulled `function.jsonc` will have the nested entry path; normalize only `entry` to `entry.ts` before comparing the candidate configuration hash. Verify no unexpected function, schema or automation change, then inspect fresh logs and perform an authorized real-client smoke test.

If temporary staging is missing, reconstruct it from a fresh snapshot that passes the baseline guard: copy each function's `base44/functions/<name>/` runtime into `<new-deploy-root>/base44/functions/<name>/`, copy its `function.jsonc`, normalize that config's `entry` to `entry.ts`, and copy the canonical Base44 project binding/configuration. From that root, run `git apply --check <absolute-path>/backend-incident-only.patch`, then `git apply <absolute-path>/backend-incident-only.patch`. The candidate guard must pass before type checks or approval.

## Broader branch differences deliberately excluded

These differences already existed between production and the Build 142 integration baseline. They are not part of this candidate.

| Function / pre-existing differing file | Broader branch behavior excluded |
| --- | --- |
| `gameRoomAction/committed-game-start-repair.ts` | Moves reconciliation signal fanout after participant leases and makes the caller update-only. |
| `gameRoomAction/community-profile-signal.ts` | Adds callbacks rechecking lifecycle ownership before profile signal writes. |
| `gameRoomAction/main.ts` | Adds legacy expected-membership validation; update-only start-repair signals; dual owner/recipient profile leases; parallel profile mirrors with barriers and serialized signal fanout. Only the separate incident hunks from this file are applied. |
| `gameRoomAction/room-membership-generation.ts` | Accepts bounded legacy expected membership strings while separately validating newly issued membership IDs. |
| `gameRoomAction/room-write-lifecycle.ts` | Extends pre-action contention retries from 6 to 8 attempts and sanitizes release-error logs. |
| `gameRoomAction/terminal-side-effect-dispatch.ts` | Retries terminal completion CAS so concurrent push/profile workers preserve each other's completion fields. |
| `pushNotificationAction/main.ts` | Sanitizes six existing best-effort logging paths. Only the queued-delivery incident hunk is applied. |
| `pushNotificationAction/error-response.ts` | Uses scalar-safe error/status extraction instead of logging arbitrary error objects. |
| `pushNotificationAction/inbox-backfill.ts` | Sanitizes legacy inbox backfill error logs. |

The broader branch also has a local-only `pushNotificationAction/safe-error.ts` helper associated with those logging changes. It is excluded along with its callers. No unrelated profile, membership or logging rollout is silently included in the five-file patch.
