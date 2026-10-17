# Social responsiveness — build 181

Prepared on 17 October 2026 in `davidganzha/supabase-game-core`, based on `b261616d`. Marketing version remains 1.0.3. The preparation checks below performed no hosted deployment or distribution. After separate explicit approval, the scoped server changes and Internal Only delivery were completed; see [RELEASE-181.md](RELEASE-181.md).

## Behavior

- Friends, invitations, and profile changes use authenticated, recipient-filtered subscriptions to the existing `app_user_signals` and `app_profile_signals` tables. RLS still authorizes every delivery. Signals contain identifiers/revisions, not profile data or room secrets.
- Catch-up waits for both the channel join response and PostgreSQL subscription readiness. This matters: the local live test demonstrated that `SUBSCRIBED` alone can precede CDC readiness and lose an immediate event.
- Reconnect/backoff, independent token renewal and heartbeats, missing-ACK deadlines, revision deduplication, and account-generation checks handle connection/session changes. Shell invalidations are buffered while reads are in flight, preserving a trailing refresh.
- Accept, decline, cancel request, and remove friend update the visible relationship immediately with pending feedback. Failed operations roll back only that relationship and reconcile with the server. Sending requests/invitations immediately shows pending feedback; success still requires the server response. Room readiness still requires successful membership/join.
- Success no longer waits an artificial 520 ms. Mutations no longer wait for unrelated profile reads. Initial friends and directory reads run independently on Supabase; the directory loads a page instead of all users. Base44 reads retain sequential startup/catch-up behavior.
- Confirmed reconnect refreshes the visible profile, including comments. A 60-second visible-profile fallback renews the server watcher lease and recovers missed reads. A 60-second shell fallback reconciles missed invalidations.
- Backend state projects friend/invite-sender profiles and history once. Browsing and exact SPY ID lookups page in PostgreSQL. Profile notifications select only self, friends, and recent viewers using existing indexes. No schema migration is needed.

## Verification

- Supabase application typecheck passed (`app:check`).
- Local authenticated application suite: **83/83 passed**. Covers duplicate/lost-response requests, transactional friend/invite rules, blocking/privacy, recipient-scoped live WebSocket events, and state recovery after disconnect. Three synthetic accounts were used; endpoints were fenced to loopback ports 56321/56322/56326.
- Local request start to recipient signal in the final full run: **569.2 ms for a friend request**, **487.0 ms for a room invite**. These single-run local observations are not production percentiles, UI latency, or physical-device measurements.
- A second real `vsn=1.0.0` WebSocket check confirmed the native parser matches actual join bindings and event payloads.
- Final native Supabase staging suite: **74/74 passed**, including 11 social transport lifecycle/parser tests and 11 UI state/rollback/stale-response tests. Existing authentication and mutation-journal tests passed too.
- Base44 configuration compatibility run: **26/26 passed** for community state, navigation, supplementary refresh, retry, and invite-cleanup policies. Final common-source changes were subsequently covered by the 74-test staging run.
- Main Supabase candidate (`SpyClash-Supabase-Main-Candidate`, `SupabaseDebug`) compiled successfully for iOS Simulator with signing disabled. Build metadata is 1.0.3 (181). Build log: `~/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/logs/build_sim_2026-10-17T19-30-08-127Z_pid93791_85e55b7f.log`.

Local backend evidence: `.local/social181-app-tests.log`, `.local/social181-v1-protocol.log` (ignored, no credentials committed).

Native result bundles are under `~/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/`: final staging `test_sim_2026-10-17T19-29-07-174Z_pid93791_129a9d4c.xcresult`; compatibility `test_sim_2026-10-17T19-27-05-382Z_pid93791_f5f42d85.xcresult`.

## Remaining acceptance boundaries

- Approved delivery completed on 17 October: live `app-services` version 9 contains only the two 181 server-file changes; Main 1.0.3 (181) is `VALID` and `IN_BETA_TESTING`, Internal Only, for David and Dima. [Release evidence](RELEASE-181.md) separates this execution from the preparation checks above.
- Two physical iPhones on real networks, end-to-end UI timing, and user visual acceptance remain unverified. Automated iOS tests do not prove those layers.
- Existing game-room close/start changes do not publish social invalidations; obsolete invitations are filtered by authoritative reads and may disappear on the fallback refresh. Acceptance always checks the room's actual state.
- Free-text name search and full competitive-history aggregation are unchanged. No blanket zero-latency claim is made.

Protocol references checked: [Supabase Realtime protocol](https://supabase.com/docs/guides/realtime/protocol), [Postgres Changes](https://supabase.com/docs/guides/realtime/postgres-changes), and [Realtime troubleshooting](https://supabase.com/docs/guides/troubleshooting/realtime-messages-not-arriving).
