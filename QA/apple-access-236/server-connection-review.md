# Independent server wait and connection-mode review

Reviewed on 2026-11-12. Production access in this review was read-only.

## Confirmed incident evidence

See [server-wait-evidence.json](server-wait-evidence.json), captured from Supabase logs and database activity.

- The affected app-services worker booted at 12:27:22.260 UTC and was terminated at 12:29:52.265 with reason `WallClockTime`; recorded CPU use was only 249 ms.
- Three build-232 requests ended together as HTTP 546 / `WORKER_RESOURCE_LIMIT`, after 150232, 119355 and 81863 ms. Each request had 41 bytes, consistent with the compact membership-check command. The logs do not contain request bodies, so that operation assignment is an inference from size and the client report.
- Three other requests on the same worker completed with HTTP 200 in 732–1183 ms.
- A different worker emitted PostgreSQL warning 25001 (`there is already a transaction in progress`) at 12:28:02.344. This is corroborating evidence of a transaction problem, not proof of the affected worker's exact pending statement.
- A later activity inspection found no ongoing application blocker or idle transaction. A snapshot after worker termination cannot exclude an earlier lock.
- Root's separate read-only identity check confirmed the affected account was native Game Center, ready and active, with no legacy link/session and no entitlements. The source therefore takes neither a legacy billing bridge nor an Apple entitlement refresh for this check.

The first failed request began at worker startup. That makes a socket left stale by a previously frozen worker less consistent with this event. The recorded CPU use rules out excessive certificate-verification CPU as the worker termination cause.

## Source review

The membership preflight has several sequential database transactions before `executeApp` installs its eight-second statement and six-second lock timeouts. No nested transaction is apparent in the membership-check path. The entitlement query returns an awaited Postgres.js `Result`, a plain Array subclass without a `then` method. Postgres.js 3.4.9's `begin` awaits the async callback, then commits; there is no result-thenable cycle in that code.

The Apple compatibility module is dynamically imported inside `appleTools`; it is not installed merely by loading the HTTP handler. With no entitlement rows and a membership-check action, this path does not invoke it.

## Proposed connection-mode change

Changing app-services' existing shared-pooler port from 6543 to 5432, while preserving host, project-qualified username, SSL, `prepare:false`, and timeouts, is a narrowly scoped compatibility repair. The module-level pool is also reduced from three connections to one per warm worker, for the capacity reason below. Supabase explicitly documents that Postgres.js' default pipelining can hang or misassociate results in shared transaction mode, whereas session mode supports pipelining. It also warns that `max_pipeline:0` breaks transactions. [Postgres.js guide](https://supabase.com/docs/guides/database/postgres-js), [connection modes and limitations](https://supabase.com/docs/guides/database/connecting-to-postgres#transaction-mode-limitations).

This establishes a real incompatibility in the previous configuration. Both the old transaction mode and new session mode passed the local Edge cold/concurrent scenarios; the exact production hang was not reproduced. These results do not prove that the mode change alone resolves the reported account check. That requires a successful runtime/live check after deployment.

A request-scoped client would be a broader change. Merely reducing `max` or relying on sequential source awaits is not a demonstrated way to disable protocol pipelining.

## Capacity tradeoff

Session mode retains one database backend per connected client until disconnection. The pool ceiling applies separately per user/database/mode combination; switching one function therefore can add a session pool alongside existing transaction traffic. [Supavisor FAQ](https://supabase.com/kb/troubleshooting/supavisor-faq-YyP5tI).

The read-only snapshot showed `max_connections=60`, three superuser-reserved slots and 13 client backends, including one idle `postgres/Supavisor` backend. In the 11:45–12:35 interval, app-services peaked at 15 completed requests per minute and three distinct workers in a minute. These aggregates are not measurements of peak concurrent connections.

The regression agent additionally reproduced immediate 503 / PostgreSQL `XX000` failures when two independent clients, each with `max:3`, competed against a local session pool limited to three backends; a single client passed. Supavisor explicitly reported `EMAXCONNSESSION`. See [local capacity observation](session-capacity-observation.json). This is a controlled local capacity limit, not a reproduction of the production wall-clock hang. It shows why preserving three connections per worker would add an avoidable session-pool risk.

The reviewed choice is therefore a shared module-level `max:1`, preserving the 15-second idle and eight-second connection timeouts. This follows Supabase's serverless recommendation and bounds each worker to one backend. It serializes transactions and can increase queueing latency. Reducing the client pool does not disable pipelining; session mode remains necessary. [Serverless client configuration](https://supabase.com/docs/guides/database/connecting-to-postgres#configure-your-client).

The final candidate handler passed the regression agent's simultaneous two-worker test on official Edge runtime 1.77.9, using one connection per worker against a shared local session pool of three. Each worker completed 117 requests, including cold/repeat/idle waves, 30-request concurrency and two-account identity checks; transaction rollback was verified. The maximum recorded duration was 2.930 seconds. The tested handler SHA-256 is `a45ce4e21f65918ad816e5af8d20a23ec9b1da0365df4d3275619858ed8e0fa5`. See [worker A](final-session-max1-worker-a.json) and [worker B](final-session-max1-worker-b.json). These are local tests, not production or device acceptance.

The configured production Supavisor session-pool ceiling was not available in this review. One connection per worker still permits aggregate saturation when many workers run. Supabase recommends considering all service connections and monitoring headroom, rather than treating the database maximum as available application capacity. [Connection pooling and limits](https://supabase.com/docs/guides/database/connecting-to-postgres/pooling-and-limits).

## Cross-route single-connection review

The exact candidate was reviewed beyond membership because its module-level client is also shared by maintenance, native AI relay and application service commands. No transaction callback was found acquiring the root pool again, or awaiting external work that needs a second slot while retaining its transaction.

- Application dispatch passes the active transaction or savepoint to domain handlers. Profile, community, inbox, membership, push and reward commands use that handle.
- Native generation commits reservation and provider-journal transactions before provider calls. The Base44 relay can therefore call back into claim/complete/fail while the originating request awaits its HTTP response. Direct AI uses the same transaction-before-provider pattern. Shared library publication within completion explicitly receives `tx`, not the root pool.
- Maintenance claims and finalizes push jobs in separate transactions; APNs delivery runs between them. Auth deletion and legacy provider reconciliation also run after their claim transaction commits. Main account deletion invokes `executeApp` only after the job-claim transaction has completed.
- Native AI relay callbacks perform database work on their transaction without external calls. The newer reward SSV route wiring is not included in the candidate; the existing reward user commands were reviewed, and their provider verification runs before transactional dispatch.

This source review found no new single-connection self-deadlock. Other requests can still queue behind a long SQL or maintenance transaction; the local concurrency tests measure only the scenarios they exercise and do not simulate every external integration.

## Slow-request diagnostic review

The new handler watcher schedules a single warning after 12 seconds. It records only an allowlisted stage and an operation mapped to fixed literal labels; request content, account identifiers, tokens, errors and provider responses are never passed to the logger. Invalid command values cannot become log labels.

The callback catches logger exceptions. Timer scheduling and cancellation failures are contained. The `warned` and `finished` flags prevent duplicate warnings and suppress callbacks after completion. Every POST completion path, including receipt replay and handled errors, runs `finish()` in `finally`; non-POST requests never start a watcher. No abort, retry or response policy is introduced. The warning can identify the last awaited phase on a future slow request, but cannot retrospectively establish the cause of this incident.

No production settings, secrets, records or deployments were changed by this review.
