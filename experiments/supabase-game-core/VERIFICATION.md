# Verification — 12 October 2026

**Result: 15/15 integration scenarios passed after a clean local database reset and migration replay.** The final run took 22.46 seconds including test-runner teardown. Tests use independent real Supabase Auth sessions, HTTP RPC requests, and real WebSocket subscriptions. The main concurrency case has six authenticated clients in one room.

## Executed environment

- Local Supabase CLI 2.120.0; supabase-js/realtime-js 2.117.3; PostgreSQL 17.11.
- Dedicated Colima profile `spyclash-supabase` (4 CPU, 6 GiB RAM, 30 GiB disk allocation).
- Supabase project ID `spyclash-game-core-test`; API 56321, PostgreSQL 56322, Studio 56323. Host listeners verified as **127.0.0.1 only**.
- Clean replay of `supabase/migrations/20261012115732_game_core.sql`, generated from the tested local database. Explicit privilege restrictions were retained independently of platform default grants.
- `CURRENT_PROJECT_VERSION` synchronized to 167 in both project files; marketing version remains 1.0.3. No iOS binary was built for this backend-only experiment.

## Scenarios

| Scenario | Result |
| --- | --- |
| local-only safety refuses remote API and database targets before connecting | PASS |
| concurrent joins, readiness and competing starts preserve every player and one match | PASS |
| capacity and expected revision are serialized under simultaneous commands | PASS |
| parallel retries return the durable original receipt; mismatched reuse is rejected | PASS |
| lost HTTP acknowledgement after commit retries exactly once after a different writer | PASS |
| replaying an acknowledged leave after rejoin preserves the new membership and reveals no secrets | PASS |
| a caller changing nested form data cannot rewrite a pending committed command | PASS |
| actual refused network request remains pending and reconnect resnapshots before retry | PASS |
| real Postgres Changes sockets converge and reconnect catches up from authoritative snapshots | PASS |
| a missed last WAL signal is recovered by bounded HTTP reconciliation while socket is disconnected | PASS |
| anonymous, outsider and peer privilege checks block snapshots, signals and secret tables | PASS |
| concurrent ballots finish one match and stale match commands cannot mutate a replay | PASS |
| leave and close race has one closed outcome with no lost membership update | PASS |
| first-delivery stale membership, settings and lobby intents are fenced independently of request replay | PASS |
| a locked room does not block the same user in another room; failed commands roll back | PASS |

Concurrency assertions verify no missing players/readiness, exactly one accepted match start, capacity/revision conflict handling, and identical durable results for simultaneous repeats. The HTTP fault proxy waits for the upstream successful response, then destroys the downstream socket, proving that response-loss recovery is tested **after commit**. A subsequent mutation by another player occurs before replay. A separate test stops the proxy listener so a real connection is refused before the command reaches the backend.

Realtime tests separately require actual WAL events at both clients, close the socket and reconnect, and compare authorized snapshots. The recovery fallback cannot satisfy the WAL-event assertions. A separate case physically closes a client's WebSocket while its room watcher remains active and verifies that bounded HTTP reconciliation recovers a missing final event.

## Cold-start defect found and corrected

The first cold run failed on Realtime delivery: both clients reported `SUBSCRIBED`, but neither received the first change. HTTP reconciliation still reached the correct revision. We reproduced this after migration reset; it was not dismissed as a passing rerun.

The installed SDK explicitly documents that default `SUBSCRIBED` can precede PostgreSQL change-stream readiness. The client now sets `postgres_changes_options: { wait: true, timeout: 15000 }`, refreshes on subscription, and performs single-flight three-second reconciliation for an active watcher. The final cold replay passed the actual event-delivery test (about 2.05 seconds), with no arbitrary pre-mutation sleep. See [Supabase troubleshooting](https://supabase.com/docs/guides/troubleshooting/realtime-postgres-changes-troubleshooting#step-6-writing-right-after-subscribed).

## Database checks

- `supabase db lint --local --schema public,game_private --fail-on warning`: passed.
- Supabase Advisors: **0 warnings, 0 errors**. Four INFO findings are intentional `rls_enabled_no_policy` on private tables: direct client access is denied, with authorization inside narrowly granted private functions. Adding permissive policies would weaken this boundary.
- Read-only acceptance audit: **5 tables, 10 functions, 1 replicated table; 15 rooms and 102 receipts checked**. Every room revision matched the signal and contiguous durable command receipts; open rooms had an active host. The final persisted fixtures had zero votes because the voting scenarios return to the lobby; vote behavior was asserted during the integration tests.
- Anonymous table/function access denied; authenticated direct private-table access and signal writes denied; published columns contain only room ID, revision, timestamp.
- Pending command payloads are deep-copied; retries retain their original membership/settings/lobby/match context.

## Scope and next acceptance boundary

This is a **local, single-spy, single-round backend prototype with automated clients**. It establishes the tested concurrency, transaction, retry, authorization and reconnect behavior. It does not establish full SpyClash rule parity, cloud network/load performance, production reliability, native iOS integration or physical-device user acceptance.

Auth fixtures are synthetic; there was no account/data migration, Base44 deployment, App Store/TestFlight action or production configuration change. The Supabase account connector required reauthentication, so no hosted project was provisioned.

Next implementation stage: connect a separate iOS test configuration to these RPCs and run real multi-device gameplay; plan the complete rules and identity migration before any production cutover.

Reproduce with `npm test` and `npm run backend:verify`. Machine-readable case results, audit counts and schema hashes are in [verification-results.json](verification-results.json). Raw credentials and raw logs remain ignored under `.local/`.
