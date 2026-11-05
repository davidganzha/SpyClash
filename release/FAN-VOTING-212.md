# SpyClash 1.0.3 (212): three visible online FAN choices

Online FAN voting now shows three fixed buttons: «Голосовать за игрока», «Шпионов нет», and «Все шпионы». Previously, the special answers shared a constrained scrolling area with the roster and could be pushed below the screen.

The first button opens a separate sheet of eligible players with avatars and names. Opening or closing that sheet does not vote; tapping a player sends the existing player-target action. The two special buttons use the existing FAN concept targets. A pending or recorded vote locks all three choices. A recorded choice displays a checkmark, and a player choice also displays the selected name.

The sheet closes when the round, match, room, account, or submission eligibility changes. The action rechecks candidate membership before sending. On compact screens, the FAN voting timer is smaller and the decorative avatar rail is hidden to preserve room for all three buttons. Existing standard online and local voting layouts are retained. Copy is provided in English, Russian, Spanish, and Ukrainian.

## Verification

- Signed `SupabaseDebug` build succeeded; installation verified build 212 and the simulator Keychain identity.
- Native XCTest UI checks passed on iPhone 17 (402×874 points) and iPhone SE 3rd generation (375×667 points), both iOS 26.5: **4 test executions passed, 0 failed**.
- Each device exercised rosters of **3, 4, 8, and 12**. All three exact Russian button labels were visible, enabled, hittable, and inside the screen without scrolling the menu.
- Opening the player sheet did not submit a vote. Its roster contained exactly N−1 candidates, excluded the current player, and allowed reaching the last candidate. Closing it preserved the unsubmitted menu.
- Fixtures for each of the three recorded vote types verified that all three buttons were disabled and only the recorded choice was selected.
- Fixed accessibility-container identifier propagation discovered by the tests. The player name is also exposed as the recorded choice's accessibility value.
- Independent source review and `git diff --check` passed.

Screenshots and machine-readable results are in `release/evidence/fan-voting-212/`. Full local result bundles are under `~/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/`; their names are recorded in `validation.json`.

These are native Simulator UI-preview checks at the tested interface settings, not a new multiplayer physical-device acceptance run. Preview mode deliberately does not send votes to production. The live server behavior was separately validated in `FAN-SERVER-211.md`; no server behavior was changed here. Build 212 has not been uploaded to TestFlight or the App Store.

`CURRENT_PROJECT_VERSION` is synchronized to 212 in `project.yml` and the Xcode project. Marketing version remains 1.0.3.
