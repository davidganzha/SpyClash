# Cloud and native iOS verification

Status as of 12 October 2026: **the local three-app native run, cloud six-client JavaScript suite, cloud three-app native repeat and full 18-check cloud database audit passed.** This document extends the earlier local backend verification. It does not certify a production migration.

## Evidence and current status

| Layer | Status | Evidence |
| --- | --- | --- |
| Local backend and harness regression | PASS | 19 tests, zero failures or errors in the executed `.local/test-results.xml`, including cloud target and native controller guards. |
| Local native application | PASS | Three separately installed Simulator instances of `com.spyclash.gamecore.lab`, build 168, with three distinct real Supabase Auth users. |
| Local native multiplayer and network recovery | PASS | Executed native control events and four checkpoints, summarized in [verification-native-local.json](verification-native-local.json). |
| Native rendered UI | Final cloud screens verified | Screenshots of all three cloud clients show Finished, revision 13, civilians winning, three players, connected live updates and concealed roles. These screenshots belong to a preceding run, as explained below. |
| Isolated cloud project | Created | `spyclash-game-core`, exact project ref `bbkfsgnordtdiblgdzkg`, Ireland, Free plan, Nano compute. |
| Cloud schema deployment | Applied | The full migration was submitted through the Dashboard in one transaction. The quick live check reported five game tables, ten functions, RLS on all game tables, no anonymous access or direct client writes, no public security-definer wrappers, and only the signals table published. |
| Full cloud database audit | PASS | All 18 checks passed after the runtime tests: five tables, ten functions, one replicated table, six rooms, 67 receipts and 12 votes. See [verification-cloud-audit.json](verification-cloud-audit.json). |
| Cloud six-client JavaScript run | PASS | Four executed tests passed, zero failed, in 19.0147 seconds. See [verification-cloud-js.json](verification-cloud-js.json). |
| Cloud three-app native run | PASS | The complete repeat exited successfully and persisted all four checkpoints and final results. See [verification-native-cloud.json](verification-native-cloud.json). |
| Manual cloud launch | PASS | All three installed apps were relaunched directly against the cloud project using `ios/scripts/manual-cloud.mjs`. Fresh independent native sign-ins and live processes were verified; no controller or fault proxy is required. |
| Physical iPhone / production SpyClash | Not exercised | The production app and Base44 backend remain outside this experiment. |

Cloud provisioning and the quick audit status above were recorded by the deployment workflow. Both native summaries were independently derived from their actual checkpoint and command-event files, and the cloud JavaScript summary from the executed JUnit report. The full cloud audit result came from the live Dashboard SQL Editor result cell and was also inspected in the saved screenshot.

## Executed local native scenario

The four native checkpoints span `2026-10-12T14:42:47.243Z` to `2026-10-12T14:42:48.571Z`. This interval covers the captured game checkpoints, not build, launch or sign-in duration.

1. Three native apps authenticated, joined one room concurrently, became ready and reached Playing at revision 9. Their own snapshots showed exactly one spy. Other player records contained no roles or words, and the spy received no word.
2. Actor B left and rejoined before the round. Replaying its original leave request returned the historical receipt at revision 4 while preserving its new membership and current room screen at revision 5.
3. The runner closed B's actual native WebSocket and stopped its loopback HTTP proxy. Other actors advanced the server to Voting, revision 11. B's vote failed with the real URLSession connection error `transport_-1004`, retained one pending command and did not reach the upstream command endpoint. B still displayed revision 9.
4. After restoring the proxy and reconnecting the native socket, B reread the authoritative snapshot at revision 11. Its original pending intent remained unchanged.
5. The proxy forwarded B's retry, observed upstream HTTP 200, and dropped the response. B observed `transport_-1005` and retained the same request ID. Another native actor then completed voting at revision 13.
6. B retried the same request again and recovered its original receipt at revision 12. Its displayed snapshot stayed current. All three apps reached Finished at revision 13, with three votes, civilians winning and no pending commands.

All three native sockets recorded the actual final WAL signal at revision 13. The event assertion is separate from the three-second snapshot reconciliation fallback. The run recorded 16 command/retry results: 14 successes and the two deliberately induced transport failures.

The ignored raw files are `.local/native-local/results.json` and checkpoints `01-all-playing.json` through `04-finished.json`. The compact tracked summary omits authentication material, player identifiers, membership/request identifiers and secret words; it retains only the room UUID and test labels. Raw checkpoints contain synthetic actors' own authorized snapshots and remain local.

## Executed cloud JavaScript scenario

The real cloud suite passed all four tests in 19.0147 seconds (`.local/cloud-test-results.xml`):

- Six independent Auth sessions serialized concurrent joins, readiness changes, competing starts and votes.
- A successful HTTPS command response was dropped after commit; retry recovered its original receipt after another writer changed the room.
- A refused connection retained the pending command, and reconnection preserved its original request ID.
- Real WAL events reached six subscribed clients and a socket that was disconnected and reconnected.

These tests exercised the isolated cloud project's actual Auth, HTTPS RPC and Realtime services. Nine synthetic accounts were provisioned for the six JavaScript and three native actors. Native acceptance was executed separately below.

## Executed cloud native scenario

The completed repeat used room `ac1eeb9d-1dd3-4a52-a115-d2f6a9ea3ef6`. Its checkpoints span `2026-10-12T15:41:13.080Z` to `2026-10-12T15:41:15.528Z`; this is the captured game interval, not build, launch or sign-in time. The runner completed with exit code 0 and persisted `passed: true` in `.local/native-cloud/results.json`.

Three independent native apps, build 168, performed real cloud Auth, REST RPC and WebSocket subscriptions. They repeated the local scenario against the allowlisted cloud project: concurrent joins/readiness, historical leave replay after rejoining, actual socket disconnect plus refused proxy connection, authoritative recovery, a response lost after commit, and retry after another native writer.

The observed faults were `transport_-1004` and `transport_-1005`. Both retained the same command ID. The final retry recovered receipt revision 12 while every current snapshot remained at revision 13. All three apps finished with three votes, civilians winning, no pending commands and an actual final WAL signal at revision 13. As locally, the run recorded 14 successful command/retry results and exactly two expected transport failures. Snapshot privacy assertions also passed.

The rendered screenshots are from the preceding run in room `c8a86386-a351-42cd-8d88-4b20af1559d4`, on the same backend and build:

- [Client A — finished](evidence/cloud-ios/client-a-finished.png)
- [Client B — recovered and finished](evidence/cloud-ios/client-b-recovered.png)
- [Client C — finished](evidence/cloud-ios/client-c-finished.png)

All three images visibly show revision 13, the completed civilian victory, connected live updates, three players and concealed private roles. That earlier game finished, but its runner's 600-second screenshot pause expired and it exited 1 before persisting a final success result. Its screenshots provide visual evidence only. The automated PASS is assigned to the complete repeat in the different room above; the two runs are not presented as one run.

## Executed full cloud database audit

The exact body of [scripts/audit-cloud.sql](scripts/audit-cloud.sql) was submitted through the cloud project's Dashboard SQL Editor, wrapped in `BEGIN READ ONLY` and `COMMIT`. The pasted body was checked for equality before execution. The live result was `PASS`, with 18 checks and no failed checks. It inspected five game tables, ten functions, one replicated table, six rooms, 67 durable command receipts and 12 votes.

The checks cover full observer visibility, RLS and client grants, allowed function privileges and empty search paths, bounded lock waits, the member-only signal policy, secret-free Realtime publication, room/signal/receipt revision consistency, active room hosts and valid current-match votes. This verifies the deployed cloud database after the test mutations, in addition to the narrower deployment-time check.

The exact sanitized result and query hash are in [verification-cloud-audit.json](verification-cloud-audit.json), with a [Dashboard result screenshot](evidence/cloud-ios/cloud-audit-pass.jpg). No client privileges or RLS rules were weakened for this read-only inspection.

## Repeating the verification

The cloud allowlist is compiled into the native app and pinned in [client/staging-project.json](client/staging-project.json). Runtime fixture setup must target that exact test project. Cloud tests use server-provisioned synthetic accounts and client publishable/anon keys; public signup, SMTP settings and production authentication are not prerequisites for this test.

The cloud fixture and acceptance reports now cover both JavaScript and native clients. Repeat the relevant checks when an implementation or deployment change invalidates their evidence:

1. Execute the 18-check read-only audit as an observer with full table visibility. A query error, restricted observer, failed check or missing result is a failed audit. Do not loosen client grants or RLS to make the audit pass.
2. Retain the completed `node scripts/cloud-test.mjs` result in [verification-cloud-js.json](verification-cloud-js.json). Repeat only if a relevant implementation or deployment change invalidates it.
3. Retain the completed `node scripts/native-test.mjs --cloud --simulators=ID,ID,ID` result in [verification-native-cloud.json](verification-native-cloud.json), with the separate screenshot-run provenance above. Repeat only after a relevant change invalidates this evidence.
4. Repeat the full cloud read-only audit after the test mutations to verify receipt/revision consistency, active hosts and vote validity as well as the access-control contract. Update the status table only from those executed results.

Do not commit runtime configuration, server keys, passwords, Auth tokens or raw credential fixtures. Test-project acceptance does not authorize production deployment.

## Limits

This is a single-spy, single-round experiment with deliberately simplified rules. It tests selected concurrent actions, a refused HTTP connection, an explicitly closed native socket and a response lost after commit. It does not establish full game parity, physical-device behavior, internet latency, Supabase regional outage handling, long-session token renewal, production throughput, or elimination of every possible HTTP 409/503. Database business rejections remain valid outcomes and must not be counted as transport failures.
