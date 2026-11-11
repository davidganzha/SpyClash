# FAN extra deals — build 229

Date: 2026-11-11. Branch: `davidganzha/fan-extra-deals-229`.
Based on committed FAN owner `4149a044` (build 227). Work was isolated from the unrelated in-progress ads/release changes in `rewarded-generation-214`. Marketing version remains 1.0.4.

## Behavior

- Two words: no spies; shuffled groups receive different words, with sizes differing by at most one.
- Everyone has a different word: no spies; one distinct enabled word per player. Starting is blocked with an explanation when the selected pool is too small.
- All spies except one: one random civilian receives the word; all others are spies.
- Each new scenario has its own probability slider, initially 0% to preserve existing settings. Existing all-spy/no-spy defaults remain 15% each. All probabilities total at most 100%.
- Surprise deals retain the existing player-only vote: the first valid ejection reveals the deal and ends in an unranked draw. Time expiry opens voting.
- Initial and reopened local cards use the same personal assignment. Split/unique results show every player's word. All-spy results continue to hide the unused common word.
- Online personal words stay private until the result. New deals require `fan_mode_v3`; old-only FAN rooms remain compatible with v2. Replay/lobby reset clears all assignments.

## Validation

- Signed Debug Simulator build passed; signature and Keychain-identity installation gate passed (iPhone 17 / iOS 26.5).
- 41 selected Swift tests passed in Debug: FAN models, local outcomes, online draws, lobby synchronization and start gates.
- The same 41 tests passed in SupabaseDebug on the final sources, including an added assertion that each new probability is a meaningful lobby change.
- UI: all five surprise-result screens passed for host and guest (10 cases); local new-deal result screens passed (3 cases); expired FAN timer still permits player voting. Three UI test methods passed across the final runs.
- 36 backend tests passed: 14 engine, 19 FAN, 3 leaderboard. Coverage includes even/odd rosters, word privacy, duplicate words, frozen retries, replay reset, compatibility and unranked outcomes. Backend typecheck passed.
- `git diff --check` passed. Screenshots: `local-split-words.jpg`, `local-unique-words.jpg`.

Simulator evidence under `~/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/`:

- `result-bundles/test_sim_2026-11-11T18-59-32-498Z_pid76448_e16ff9a5.xcresult` (Debug unit tests).
- `result-bundles/test_sim_2026-11-11T19-06-11-274Z_pid76448_2fdb5d88.xcresult` (SupabaseDebug unit tests).
- `result-bundles/test_sim_2026-11-11T19-03-32-853Z_pid76448_36cbf423.xcresult` (final online/local result UI tests).
- `result-bundles/test_sim_2026-11-11T19-00-56-797Z_pid76448_e7f88c77.xcresult` (passed expiry-voting test; initial result tests used incorrect accessibility element types, corrected before the final passing run).

Backend commands, from `experiments/supabase-game-core`:

```sh
/Users/davidganzha/.deno/bin/deno test --quiet --config supabase/functions/full-game-core/deno.json tests/full-core-engine
/Users/davidganzha/.deno/bin/deno check --config supabase/functions/full-game-core/deno.json supabase/functions/full-game-core/index.ts
```

## Release boundary

No deployment, App Store/TestFlight upload, or production mutation was performed. Physical-device and real multiplayer acceptance remain unverified. Existing online FAN is owned by Supabase `full-game-core`; ordinary Debug uses Base44, whose legacy game backend has no FAN implementation. Online activation requires a separately approved deployment of the changed Supabase function and a matching Supabase-configured client. No database migration is needed: assignments are stored in existing JSONB room state.
