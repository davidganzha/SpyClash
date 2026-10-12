# Full original game-core parity

Baseline: `568720f1` (2026-10-12). This is a migration contract, not a claim that the full core is already migrated. Source paths below are repository-relative; line numbers refer to this baseline.

## Verified source boundary

- `base44/functions/gameRoomAction/main.ts` is the authoritative entry (`function.jsonc`), with 48 local helper imports. Its directory contains 50 non-test TypeScript files and 55 test files.
- The local core tree is identical to release branch `davidganzha/testflight-all-fixes-165` at `60be7f03`; both tree hashes are `d52d353adae84857ade75da627f3d6db7ac2e4b2`. The primary checkout and other locally available repair branches have older core trees.
- The coordinating agent additionally performed a fresh, read-only pull of the deployed Base44 function: all 50 TypeScript source files were byte-equal to this baseline, with deployed `entry.ts` mapped to local `main.ts`. Evidence: `.local/canonical-full-core-manifest.json`. No deployment was performed.
- Native API: `SpyClash/Services/Base44Client.swift:427–960,1962,3060,3110`. Public models: `SpyClash/Models/SpyModels.swift:3660,3696,3776`. Existing gameplay UI: `SpyClash/Views/GameView.swift` and its original subviews.

## Exact native action inventory

There are **32 current native room-action names**. Swift `startGame` is an orchestration of `arm_roulette` and `complete_game_start`, not an original `start_game` server action. In the table, line references are to `base44/functions/gameRoomAction/main.ts`.

| # | Action | Rule and state transition that must survive | Source |
|---|---|---|---|
| 1 | `get_room` | Authorized viewer projection; reads may reconcile start/terminal state; no secret persistence fields. | 4836 |
| 2 | `get_active_room` | Preferred room plus bounded host/participant lookup; resumes waiting, ready, roulette and playing rooms. | 3800,4710 |
| 3 | `create_room` | Authoritative actor identity; generated six-character code; waiting, questions, 900 seconds, one spy; lobby schema 2 and initial revisions. | 1496,1856,4719 |
| 4 | `join_room` | Fresh join only in waiting, maximum 12; existing member may resume an active room; membership-generation and capability checks; invite resolution. | 1908 |
| 5 | `begin_ready_check` | Host, waiting, at least 3 players, valid spy count/capable roster and valid enabled word pool; ready_voting with cleared readiness. | 2074 |
| 6 | `return_to_waiting` | Host; ready_voting → waiting, readiness reset. | 2096 |
| 7 | `vote_return_to_lobby` | Despite its legacy name, **host-only immediate return**, not majority voting; expected match; clears active match while retaining eligible roster and lobby settings. | 2131 |
| 8 | `kick_player` | Host in lobby; stable target user ID preferred, target membership generation fenced; remove readiness/roster and clamp spy count. | 2175 |
| 9 | `toggle_ready` | Participant in ready_voting; capture intended boolean once, never toggle again when retrying the same intent. | 2206 |
| 10 | `vote_play_again` | Finished member, committed terminal outbox and source-match fence; unanimous eligible votes automatically arm replay. | 2236 |
| 11 | `reset_room_for_replay` | Host, finished, committed terminal outbox, unanimous replay votes; keep eligible roster/settings, clear old match state. | 2275,2346 |
| 12 | `return_finished_room_to_lobby` | Host, finished and committed terminal outbox; no replay unanimity required; repeat in waiting is idempotent. | 2368 |
| 13 | `update_game_mode` | Host waiting; questions/associations only; legacy mode patch (does not itself increment lobby revision). | 2384 |
| 14 | `update_game_duration` | Host waiting; integer duration 60–900 seconds. | 2398 |
| 15 | `update_lobby_state` | Canonical state with mutation ID, fingerprint and expected revision; same ID/body replays, changed body or stale revision rejects; capability and spy-count reconciliation. | 2412 |
| 16 | `arm_roulette` | Host waiting or ready_voting; all-ready required in ready_voting; ≥3 players; expected lobby revision, enabled pool ≥2, valid target; freeze server-assigned spies once and stamp intro. | 2582 |
| 17 | `complete_game_start` | Any current participant after the server's 3-second intro; repeat is safe; create match/start event once; playing, but timer remains unstarted. | 2675 |
| 18 | `mark_role_card_read` | Same-match participant acknowledgement stored on server; last active reader starts the game timer; evaluate terminal parity. | 2786 |
| 19 | `pause_game` | Host playing with a started, unexpired timer; preserve first paused timestamp on repeat. | 2820 |
| 20 | `resume_game` | Host; add floored elapsed pause seconds once and clear pause timestamp. | 2832 |
| 21 | `advance_question` | Questions mode, active current asker only; private turn order; eight questions lead to results. | 2844 |
| 22 | `advance_association` | Associations mode, active current speaker only; each active player speaks once per round, then advance round. | 2866 |
| 23 | `start_association` | Host associations; initialize or reconcile speaker and encoded order state; safe repeat. | 2906 |
| 24 | `stop_association_spin` | Active associations participant; settle existing spin without rerolling chosen order. | 2953 |
| 25 | `mark_answer_heard` | Questions, current asker and asking phase; delegates to the same authoritative question advance. | 2982 |
| 26 | `continue_round` | Any active questions participant at results; next turn and round, count zero, feedback reset. | 3004 |
| 27 | `request_vote` | Active non-spectator in current playing match; pause/deadline checks; request threshold `ceil(0.51 × N)` opens a generated vote-round ID. | 3024 |
| 28 | `cast_detective_vote` | Exact vote-round ID, one immutable ballot, no self/inactive target; **N−S ejection threshold**, early no-viable-candidate cancellation, not plurality. Ejection can continue or end match; cancellation has shared event identity and 3-second presentation lead. | 3088 |
| 29 | `submit_spy_guess` | Active assigned spy in exact match; safe text, case-insensitive/accent-sensitive comparison; correct → spy, wrong → detectives for the whole match. | 3286 |
| 30 | `finalize_expired_room` | Exact match/start timestamp; server elapsed timer decides spy win, never a client winner. | 3967,4852 |
| 31 | `close_room` | Host and current membership/revision; finalize terminal decision/outbox, durable close signal and Live Activity end work before deletion. | 3298,3984 |
| 32 | `leave_room` | Membership/revision-fenced and safe if already departed; host lobby exit closes; pre-timer exit abandons frozen start; live exit retains departure/elimination tombstones, transfers host, repairs turns/vote state and can finish; finished host transfers or closes. | 3316,3997 |

The dispatcher also accepts compatibility `finish_room` (host, server timer determines result) and deliberately rejects `record_finished_online_game` (client cannot record its own result). These are not additional current native actions. `get_leaderboard`, admin profile backfill and internal terminal/profile repair commands are adjacent integration operations, not player room actions.

## Request and response contract

`GameRoomActionPayload` (`Base44Client.swift:3110`) carries:

- Routing/auth: `action`, `access_token`, `client_capabilities`, `room_id`, `room_code`, `player`. Resolve the actor from verified authentication; client `player` never authorizes another identity. Current multi-spy capability is `multi_spy_v1`.
- Lobby/start: `mode`, `game_mode`, `game_duration_seconds`, `state`, `plan`, `roulette_target_email`, `mutation_id`, `expected_lobby_revision`, `expected_revision`.
- Actor/round fences: `target_user_id`, `target_email`, `expected_target_membership_id`, `join_membership_id`, `expected_membership_id`, `expected_match_id`, `expected_game_started_at`, `expected_detective_vote_round_id`.
- Action values: `return_to_lobby_vote`, `guess`, legacy `winner` (not authoritative).

`LobbyStatePayload` (`SpyModels.swift:3696`) includes mode, duration, `lobby_spy_count`, `spies_know_each_other`, word source (`none/saved/ai/manual`), source pack ID/name, theme/category, word count, recommended/custom count mode, and word pool entries `{id?,word,enabled}`. Canonical pool maximum is 200; start uses at least two enabled words. Preserve saved/manual/AI source metadata and exact word selection semantics. `authoritativeStartPayload` (`main.ts:447`) accepts the proposed word only if it belongs to the server-validated selected pool and replaces mode/duration/pool/category from authoritative lobby state.

`StartGamePayload` (`Base44Client.swift:3060`) includes the proposed word, category, initial question pair, mode/duration, round/question state and reset collections. Server rules sanitize it and own spy assignments, timestamps, match identity and terminal outcome. Do not migrate it as an arbitrary client patch.

Authorized migration adaptation: the coordinating task requires the new server to select the exact word and roulette/initial-turn vector itself from the authoritative pool/roster. Thus the old client-proposed `plan` is a compatibility input, not authority in the new engine; pool/settings, role privacy and intro timing remain unchanged. Word generation stays on the existing Base44 generator for this stage; this core migration does not call or replace the production generator during tests.

Original commands normally return **the caller's projected `GameRoom`**. Active-room lookup is nullable; leave/close also permit success-only responses. The migration may use a secret-free commit receipt followed by an authorized snapshot internally, but the Swift facade must retain the existing view-model contract, monotonic state application and recoverable receipt-success/read-failure behavior. Preserve semantic error codes/status, not Base44 lease errors.

`GameRoom` (`SpyModels.swift:3776`) field families to preserve:

| Family | Fields |
|---|---|
| Identity/phase | `id`, `code`, `host_email`, `viewer_membership_id`, `match_id`, `status`, `players`, `room_revision`, `lobby_revision`, `lobby_schema_version` |
| Roles/words | `spy_email`, `spy_emails`, `revealed_spy_emails`, `lobby_spy_count`, `spies_know_each_other`, `exclusion_vote_threshold`, `secret_word`, `word`, `category`, `word_pool`, all authoritative `lobby_*` settings above |
| Start/timer | `roulette_target_email`, `intro_started_at`, `cards_read`, `game_started_at`, `game_duration_seconds`, `game_paused_at`, `game_paused_total_seconds` |
| Turns | `game_mode`, `round_number`, `questions_in_round`, `current_asker_email`, `current_answerer_email`, `question_phase`, `countdown_started_at`, `current_answer`, `current_answer_feedback`, `player_feedback` |
| Voting/result | `vote_requests`, `detective_votes`, `detective_vote_round_id`, all four `detective_vote_cancellation_*` fields, `spectators`, `eliminated_emails`, `spy_guess`, `winner`, `terminal_reconciliation_pending` |
| Readiness/replay | `ready_players`, `replay_source_match_id`, `return_to_lobby_eligible_player_emails`, `replay_eligible_player_emails` |

Players currently expose email plus name/avatar and conditional user/membership IDs. Ballots use `{voter_email,voted_for_email}`. Stable authenticated UUIDs can remain the storage identity; adapt the existing UI identifiers consistently without fabricating additional roles or losing profile linkage.

## Viewer privacy is part of gameplay parity

Use `room-projection.ts:186` as the oracle, including its helper policies, rather than returning stored room JSON.

- Before finish, a civilian does not see assigned spy identities. A spy sees self, or the entire spy team only when `spies_know_each_other` allows it. Eliminated spies are explicitly revealed. Finished rooms reveal all spies and the exact word to authorized retained participants.
- A spy's exact word is `CLASSIFIED` before finish. Candidate `word_pool` remains visible for legitimate guesses. Active snapshots must also redact duplicated lobby pool/theme/source fields that could reveal the exact word indirectly.
- Lobby source-pack identity is host-only; lobby candidate words are visible to participants while configuring the lobby. Membership IDs are scoped to the viewer, with target IDs available to the host only in lobby. Profile user IDs follow the retained, nondeparted lobby policy.
- Association `current_answer` contains the public encoded spoken/spinning/order state. Questions use that storage field for private turn ordering; their projection returns an empty value.
- Do not expose private departure tombstones, writer leases, repair/outbox contents, auth tokens or terminal intent. `terminal_reconciliation_pending` is only a boolean.
- An old vote without a vote-round ID must not appear as a current scoped ballot. Replay eligibility excludes departed players, deduplicates stable user identities and includes retained eliminated players.

## Reuse map and transaction boundary

| Existing helper group | Preserve |
|---|---|
| `lobby-state-policy.ts`, `start-word-pool-policy.ts`, `content-safety.ts` | Canonical settings, word selection/safety, revision/fingerprint rules. |
| `multi-spy-policy.ts` | 3–12 players, 1–3 spies bounded by roster (`floor(N/3)`), capability checks, secure unbiased frozen role assignment. |
| `question-turn-order.ts`, `question-round-policy.ts`, `association-turn-order.ts`, `round-action-access.ts` | Both complete modes, actor permissions, deterministic turn/roster repair. |
| `detective-vote-policy.ts`, `game-timer-policy.ts` | Majority request, N−S exclusion, immutable scoped ballots/cancellation, pause and server deadline semantics. |
| `room-result-policy.ts`, `game-round.ts` | Intro, card acknowledgement, exact start/terminal identity, pre-timer departure and result rules. |
| `replay-policy.ts`, `replay-auto-start-policy.ts`, `active-game-lobby-return-policy.ts` | Unanimous automatic replay, retained roster, source-match fences, host return rules. |
| `lobby-kick-policy.ts`, `finished-room-departure-policy.ts`, `room-membership-generation.ts` | Membership-safe kick/leave, host succession, stale intent rejection. |
| `room-projection.ts` | Exact viewer-specific compatibility shape and privacy. |
| `competitive-stats.ts`, `game-history-idempotency.ts`, `terminal-outbox-commit.ts` | Exactly-once history/stat effects and durable terminal delivery. Replace storage adapters, keep outcomes. |

Replace Base44-specific CAS/lease machinery (`room-write-cas.ts`, `room-write-lifecycle.ts`, billing/account lifecycle leases and storage retry/recovery wrappers). Recreating those leases on Supabase would carry over the failure architecture we are migrating away from.

Recommended extraction: retain pure helpers and make each action a typed reducer over canonical room state, verified actor and frozen intent, with injected clock/randomness. A trusted server transaction locks actor/request receipt and room, validates generations, runs the reducer, writes room/membership/result/history/outbox plus revision signal and immutable receipt, then commits. A TypeScript server can reuse helpers while holding a direct PostgreSQL transaction; a SQL port needs differential fixtures against the same helpers. A lock acquired in one RPC does not remain held across a later HTTP call. Never accept client-computed arbitrary room patches or distribute privileged database credentials to iOS.

Terminal effects must not be reduced to a winner field. Commit terminal identity and history/stat/outbox work atomically; retry delivery separately for push, Live Activity closure and community-profile mirrors. Preserve close tombstones/revision signals so clients learn that access ended. Full account/purchase/community migration is separate, but a game must not lose its own result effects during this separation.

## Historical prototype gaps at the source baseline

At baseline `568720f1`, the accepted prototype (`supabase/schemas/game_core.sql`) demonstrated transaction, idempotency, privacy and reconnect mechanisms for a simplified game. Its 10 commands, one spy/static words, lobby/playing/voting/finished phases and plurality vote did **not** implement the original 32-action protocol. That baseline test adapter used local role-card confirmation, and `GameView` selected `SupabaseGameTestView` under the test flag instead of the normal full UI. These are historical gaps that motivated the full-core work, not a description of the newer implementation. See [FULL-CORE-VERIFICATION.md](FULL-CORE-VERIFICATION.md) for its separate implementation and acceptance status.

The implementation order derived from those gaps was:

1. **Protocol/storage first:** full canonical state, six-character join codes, stable actor/room/membership/lobby/match/vote-round identities, all 32 action handlers, projected responses and immutable request receipts. Keep room locks independent.
2. **Complete lobby/start:** authoritative saved/manual/AI word settings, capability/multi-spy rules, ready check, frozen roulette and server card acknowledgements. Word-pack acquisition services are dependencies; a migrated game must accept their authoritative settings without requiring a redesigned lobby.
3. **Complete play:** question/association turn machines, pause/deadline, vote request/exclusion/cancellation, spy guesses, departure repair and all win conditions.
4. **Terminal/replay/integration:** durable history/stat/outbox effects, close signals, unanimous replay and both lobby-return paths. No best-effort result recording after an already-acknowledged finish.
5. **Existing UI and device acceptance:** route the original Swift facade and original gameplay UI to the full core behind the isolated test configuration; remove prototype no-ops instead of disguising unsupported actions. Keep production routing unchanged during this work.

Verification should reuse the 55 original helper-test files as behavioral oracles and add real database/HTTP tests for complete two-mode traces, concurrency, lost acknowledgements, immutable retries, stale generations, unauthorized reads and privacy throughout phases. Cover 3/6/9-player spy counts; restart/rejoin in every phase; host departure before/after card reads; paused expiry; vote cancellation and roster change; exact-once history/outbox on concurrent terminal actions. Then exercise the original UI with a physical iPhone and independent clients, including actual network loss. A green simplified-core suite alone is insufficient parity evidence.
