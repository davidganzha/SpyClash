# Membership access timeout — source build 236

The user reported a new failure in TestFlight build 232 at 12:27–12:28 UTC on 2026-11-12: `IAP-BUY-ELIGIBILITY-NONE: ACCESS_UNVERIFIED/HTTP_503/TRANSPORT_INTERRUPTED`. This happens before Apple checkout. Build 232 and the relevant current native purchase/session code are identical.

## What the evidence establishes

The client assigns synthetic HTTP 503 to non-cancellation URLSession failures, so the screenshot alone does not establish an HTTP 503 server response. The wider server log window reveals three requests that waited 82–150 seconds and ended with HTTP 546 when their worker reached its wall-clock limit. CPU use was 249 ms. Other requests in the same worker succeeded. See [sanitized evidence](server-wait-evidence.json) and [independent review](server-connection-review.md).

The failing requests had 41-byte bodies, consistent with `membership/check`; their assignment to that operation is an inference from request size and the screenshot, because the logs do not contain bodies. A read-only account lookup confirmed a ready native Game Center account, active profile, no legacy link/session and no Apple entitlements. That membership-check path does not call Apple or install the certificate compatibility adapter.

The database had no remaining blocker when inspected after worker shutdown. This does not exclude a lock during the incident. A separate maintenance worker reported `there is already a transaction in progress`, which is corroborating evidence rather than proof of the affected request's pending statement.

## Prepared repair

`app-services` uses Postgres.js 3.4.9 with a shared module-level pool. Its hosted connection was routed through Supavisor transaction mode, port 6543. Supabase documents that Postgres.js default pipelining can hang queries or return mismatched results in that mode, while session mode supports pipelining. Setting `max_pipeline:0` is not a supported workaround because it breaks transactions. Sources: [Postgres.js guide](https://supabase.com/docs/guides/database/postgres-js), [connection-mode limitations](https://supabase.com/docs/guides/database/connecting-to-postgres#transaction-mode-limitations).

The prepared change uses the same shared pooler host and tenant-qualified username on **session port 5432**. Project guards, credentials, database, SSL, `prepare:false`, and timeouts are preserved. The module-scoped pool is reduced from three connections to **one per warm worker**, following Supabase's serverless guidance and a local capacity countertest: two clients each allowing three connections exceed a three-session pool ceiling and fail immediately. That capacity failure is distinct from the reported 150-second wait. Local database routing is unchanged. This removes a documented incompatible configuration; successful device acceptance is still needed to establish whether it resolves this incident.

Because the exact wait has not reproduced locally, the handler also records a single warning if a request is still unfinished after 12 seconds. It contains only allowlisted operation/stage labels. It never records identity, request data, credentials, transaction payloads or error text; never cancels or retries the operation; and always clears its timer on completion. A logger failure cannot alter the response. This should locate a future stall without another speculative repair.

The deployment candidate is the freshly retrieved **v25** bundle with `app-services/index.ts` and `handler.ts` changed and one diagnostic helper added. All 77 original files and the new helper are accounted for in [baseline](live-baseline.json) and [78-file candidate manifest](candidate-manifest.json); [complete production patch](candidate.patch). Unrelated newer source changes, including reward/loyalty work, are excluded. The native source build is synchronized at 236, marketing version remains 1.0.4. No new native behavior or TestFlight upload is included in this repair.

## Validation and operational limits

- Strict Deno type checking passed for the exact hosted candidate and the full current source entrypoint.
- All 10 focused diagnostic tests passed: delayed observation without retry/cancellation, private-data exclusion, independent concurrent request state, logger failure containment, timer cleanup and unchanged rejection/replay responses.
- The final candidate passed **234 requests across two simultaneous Supabase Edge Runtime 1.77.9 workers**, each using one session-pool connection. Tests include cold membership-first waves of 3/12/30 requests, repeats, reconnect after the 15-second idle timeout, two-account response isolation and transaction rollback. The largest request took 2.930 seconds, below the 20-second test deadline. Both workers made zero external-provider calls. [Worker A](final-session-max1-worker-a.json), [worker B](final-session-max1-worker-b.json).
- Baseline tests also passed through direct, transaction and session connections in standard Deno and Edge Runtime 1.77.9. Each combination checked 117 requests and rollback. **The exact production hang was not reproduced**; the mode repair removes a documented incompatibility, while the added stage warning supplies missing evidence if another wait occurs.
- Applying the tracked patch to the 77-file baseline reconstructs all 78 candidate hashes exactly. Generated Deno cache/lock files are excluded from the explicit deployment file array.
- A read-only SSL negotiation confirmed that the existing pooler host accepts connections on port 5432. This is reachability evidence, not an authenticated database or Edge runtime acceptance test.
- Independent source review found no blocking defect in the mode change and confirmed that the native purchase check remains fail-closed.
- Session mode retains a backend per connected client. The new limit of one applies per worker, not globally. The observed database snapshot had 13 client backends out of a configured maximum of 60; observed request rates were low. The 15-second idle timeout is preserved, but production connection occupancy must still be checked after an approved deployment.

## Approval and acceptance

No production deployment has been performed for this change. A new explicit approval must name replacement of `app-services` in project `bbkfsgnordtdiblgdzkg` with this reviewed candidate. Before deploying, re-read the hosted bundle and compare it with the v25 baseline. Preserve gateway JWT verification.

After an approved deployment, retrieve and compare every candidate file, confirm function startup and successful membership checks, and inspect for further delayed 546 responses and connection pressure. The user cannot currently perform the requested device retry; that acceptance remains pending. A successful smoke request does not establish that a real Apple purchase or restore succeeds.
