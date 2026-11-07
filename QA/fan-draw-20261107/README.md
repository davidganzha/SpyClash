# FAN surprise draws — 1.0.4 (221)

FAN no longer offers concept guesses. Players vote for another player. If the hidden assignment is `all_spies` or `no_spies`, the first valid ejection ends the match as a draw and reveals the scenario with a shared card-flip animation. The ejected player receives the result too. A standard assignment retains ordinary ejection outcomes.

All FAN assignments use the same public timer behavior: at zero, voting stays open until an ejection. An unfinished ballot keeps its votes; a split ballot starts another vote. This does not reveal the secret assignment through deadline behavior. A room that loses too many participants closes without recording a result.

Draw history is visible with `winner=draw`, `won=null`, `ranked=false`; wins, losses, streaks, role win rates, rating and competitive achievements are unaffected. Settings/rules and result text support EN/RU/ES/UK. Reduce Motion reveals immediately. Old split-vote feedback cannot cover a finished result.

## Compatibility and release boundary

The new server requires `fan_mode_v2` for FAN rooms; the client advertises v1 and v2. Upgraded clients can restore old saved rosters and refresh their capability on their next action. Historical v1 finished outcomes remain readable.

Client and backend must be rolled out together under a separately approved production plan. This FAN change was **not deployed**, uploaded to TestFlight, or submitted to App Review. Physical-device, production multiplayer and user acceptance remain unverified. The optional cloud smoke script was updated but not run.

This scoped checkpoint follows `a971a060` (the independent AdMob build 220). Only the build number conflicted during integration; all AdMob changes were retained. Marketing version stays 1.0.4. The final number is 221; the verified FAN application code is identical to the candidate numbered 220 below.

## Verification

- Signed iPhone 17 Simulator build, iOS 26.5, with ads disabled. Installed through the repository signature/Keychain identity checker.
- 127 Swift tests passed on the final build 220: FAN probability/player ballots, local outcomes, online draw/history/deadline/cancellation behavior, and existing OnlineRoundStateTests regressions.
- All 4 FAN UI tests passed before the metadata/independent-AdMob integration: 3/4/8/12-player rosters, immutable recorded ballot, actual player vote after expiry, and both draw scenarios for host/guest with stale cancellation feedback seeded.
- The draw and expired-ballot UI tests were repeated on build 220: 2 passed, 0 failed. Final UI result: `test_sim_2026-11-07T19-14-13-225Z_pid70979_ba49bf16.xcresult`.
- Backend: 31 engine/leaderboard tests, 9 achievement tests, and 15 local Auth/PostgreSQL/RLS/WAL integration tests passed. Includes atomic single history/outbox creation under duplicate terminal votes, all-viewer reveal, no premature timer ending, restore from saved v1 capabilities, and replay.
- Backend typecheck, optional smoke-script syntax check and Git whitespace checks passed.

Swift evidence is in XcodeBuildMCP workspace `SpyClash-f8b83e29e9ef`. Final unit result: `test_sim_2026-11-07T19-13-37-656Z_pid70979_4b39fc08.xcresult`. Earlier complete UI suite: `test_sim_2026-11-07T19-11-07-419Z_pid70979_154d6c0e.xcresult`.

Backend checks (from repository root):

```sh
deno test --config experiments/supabase-game-core/supabase/functions/full-game-core/deno.json experiments/supabase-game-core/tests/full-core-engine
deno test --config experiments/supabase-game-core/supabase/functions/app-services/deno.json experiments/supabase-game-core/tests/app-services/achievements_test.ts
deno check --config experiments/supabase-game-core/supabase/functions/full-game-core/deno.json experiments/supabase-game-core/supabase/functions/full-game-core/index.ts
node --check experiments/supabase-game-core/scripts/fan-mode-cloud-test.mjs
```

Local integration uses `node scripts/full-core-local.mjs` from `experiments/supabase-game-core` with its existing loopback services and dependencies. Test stdout was captured in the agent run; local server runtime output remains in `.local/full-core-server.log`.

Preview arguments (Debug only, no network game):

```text
--spyclash-ui-preview --spyclash-preview-tab=game --spyclash-preview-room=finished --spyclash-preview-lang=ru --spyclash-preview-fan-mode --spyclash-preview-fan-draw=all_spies
--spyclash-ui-preview --spyclash-preview-tab=game --spyclash-preview-room=finished --spyclash-preview-lang=ru --spyclash-preview-fan-mode --spyclash-preview-fan-draw=no_spies
--spyclash-ui-preview --spyclash-preview-tab=local --spyclash-preview-lang=ru --spyclash-preview-local-phase=fan-draw --spyclash-preview-local-fan-scenario=no_spies
```

Final runtime build was rebuilt separately from XCTest products and passed `scripts/install-ios-simulator-app.py`; bundle SHA-256 `4646686a39869be9db34377f6c6078827f843753fdd9787ddcbb7e414818e318`. The test product directory included unsigned XCTest debug symbols and was correctly rejected by the install checker; the fresh runtime artifact contains no test payload. This validates bundle identity, not real sign-in.

Local draw screens were visually checked in both scenarios on build 220; see `local-all-spies.png` and `local-no-spies.png`. A short reveal video is saved with this chat's local visualization artifacts.
