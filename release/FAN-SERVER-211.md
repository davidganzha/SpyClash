# SpyClash 1.0.3 (211): FAN server activation

On 5 November 2026, the user explicitly authorized deployment of the prepared FAN game function and online verification of all three ballot types. Supabase project `bbkfsgnordtdiblgdzkg`, function `full-game-core`, was updated from version 12 to version 13. JWT verification remains enabled.

## Published behavior

- Ballots can target another player, `__fan_no_spies__`, or `__fan_all_spies__`.
- A special answer needs every active player's vote. A correct answer gives every player a win; a wrong answer gives every player a loss.
- Accusing a player needs N−1 votes. In the standard FAN scenario, finding the spy wins for detectives. An accusation in either anomalous scenario loses to the system.
- Split ballots continue play; players cannot change an already submitted ballot. FAN word guessing is disabled, and FAN results are unranked.
- FAN settings default off. A compatible client advertising `fan_mode_v1` is required for FAN rooms.

## Deployment scope

The package starts from a fresh export of live `full-game-core` version 12 and overlays only the eight changed FAN game files and the new FAN policy. Every existing `app-services` dependency in that function is preserved byte-for-byte, excluding unrelated loyalty/billing work from this publication. The existing `lobby-host-transfer-policy.ts` dependency, omitted by the remote export, was included from its unchanged build-205 source.

No database migration was needed. No separate `app-services`, Base44 function, client binary, TestFlight build, or App Store release was published. Project build metadata is synchronized to 211 for this checkpoint; marketing version remains 1.0.3.

The original server export and exact deployment payload are kept locally under `.local/fan-server-20261105/`. The committed candidate manifest identifies every file by SHA-256. A postdeployment read confirmed all 44 published files match the reviewed payload exactly.

## Verification

- Exact staged package: type check passed and all 26 engine/leaderboard/FAN tests passed.
- Live validation uses `experiments/supabase-game-core/scripts/fan-mode-cloud-test.mjs` with four pre-existing synthetic Auth users and rooms created only by that run. Auth credentials stay in memory; reports contain no tokens or passwords.
- Live HTTPS/Auth verification: **6/6 passed**, with four synthetic players across six owned rooms. Both special answers waited for all four votes and awarded all players wins; player accusation in the standard FAN scenario awarded the correct role results. Wrong concept and anomalous player accusation awarded four losses. Split votes continued play, and a conflicting second ballot was rejected.
- Five completed matches produced exactly one personal result per player (20 total), all unranked. Duplicate final-request retries returned the original response. The split-vote match produced no history.
- All six owned test rooms were closed successfully; cleanup errors: zero. Sanitized live results and the database cross-check are recorded in `release/evidence/fan-server-211/`.

Online HTTP tests verify server behavior. They do not constitute a new physical-device or multi-device UI acceptance run.
