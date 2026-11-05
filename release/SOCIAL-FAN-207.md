# SpyClash 1.0.3 (207): achievements, invitations, FAN mode

Prepared 5 November 2026 on `davidganzha/social-fan-mode-207`, based on committed build 205 (`d553cbd0`). The older build 148 checkout and unfinished build 206 work remain untouched.

## Delivered behavior

- Ten achievements in own and public profiles: first mission, field agent, veteran, first victory, ten wins, first/ten spy wins, first/ten detective wins, five wins in each role. The server derives progress from deduplicated completed multiplayer history. Local games and client-provided profile counters cannot award badges. Existing compatible history counts retroactively.
- A centered, animated invitation card shared by Radar, friends and community invitations, including above presented sheets. Account-scoped queues and a shared join guard prevent concurrent joins. Reduce Motion is supported.
- Independent permissions: friends default allowed, strangers default denied, Radar uses its existing allow/ask/block behavior. Server enforcement covers sending, visibility and acceptance, including revocation and blocked senders.
- Collapsible FAN settings in local games and the current Supabase online lobby. FAN defaults off, with 15% all-spies / 15% no-spies / 70% normal when enabled. Each anomaly slider ranges 0–99%; adjusting one caps the other so total<=100. Normal is the remainder, including 0%.

## FAN rules

- Normal scenario has exactly one spy. All-spies gives every participant a spy card and no secret word; no-spies gives everyone the word. The sampled scenario is private until the result.
- Teammate disclosure and word-guess actions are disabled throughout FAN mode. The lobby and vote threshold do not reveal the assignment.
- Ballots can name another player or choose either concept. A concept needs every eligible active vote. A correct unanimous concept wins for all; an incorrect one loses to the system. Split ballots continue the round once everyone has voted.
- Player accusations use N-1 votes regardless of the hidden scenario. In the normal scenario they retain the existing elimination rules. In an anomalous scenario an accusation loses to the system.
- Timer expiry awards the system in anomalous scenarios and the spy in normal scenarios. Departure/replay/reconnect preserve the server-owned rules; incompatible clients are refused FAN rooms.
- FAN matches are unranked. Completed FAN games count toward multiplayer participation/win achievements. Collective wins never grant role-specific badges.

## Validation

- SupabaseDebug iOS Simulator build passed.
- 42 selected native tests passed: FAN probability/vote rules, invitation queues, achievements and existing lobby/vote synchronization.
- 30 native transport/recovery tests passed, including capability propagation on reads and durable commands.
- 26 server-engine tests passed, including 9 new FAN tests.
- 15 real local Auth/Postgres game integration tests passed, including FAN unanimity, old-client rejection and concurrent identical retries producing one result/history/outbox.
- Achievement policy/projection tests 6/6; invitation policy tests 2/2. Application-services and push integration suites passed 31/31 after the final inbox/push permission fix (including three new end-to-end cases).
- The local database is a dedicated Colima Supabase test stack, verified via its SSH socket and Docker port mapping. No hosted database was used for fixture tests.
- Simulator visual checks covered the invitation card, expandable local FAN controls and achievement presentation. The community-stranger invitation was also verified above a privacy sheet; ordinary previews no longer open invitation fixtures automatically. Final native rerun: 42/42 passed.

## Release boundary

Nothing was deployed, uploaded to TestFlight or submitted to App Store. Server activation requires deployment of the prepared `app-services` and `full-game-core` functions, followed by a compatible client rollout. The app-services deployment includes its inbox and push worker source rechecks. No database migration is required: settings, results and profiles use existing JSON records. A fresh explicit approval naming production target/operation is required immediately before any such action.

Live multi-device networking, physical-device animation/performance and user acceptance remain unverified. The historical Base44 gameplay transport does not implement FAN; its online FAN settings are hidden. Local FAN remains available.

Validation artifacts: `/tmp/spyclash-social-fan-207-final-tests.xcresult`, `/tmp/spyclash-social-fan-207-transport-retry.xcresult`. Visual evidence is in `/Users/davidganzha/.codex/visualizations/2026/11/05/01a1a91f-913f-7b02-8dfa-371ccba8ffcb/spy-clash-207/`. An initial isolated test-target compiler crash in a directly passed actor-isolated Binding setter was resolved by an explicit forwarding closure; the rebuilt target and all 30 transport tests then passed.
