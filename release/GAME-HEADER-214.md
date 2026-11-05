# SpyClash 1.0.3 (214): compact game controls and confirmation

The host's active-game header now contains three 44-point icon buttons in one row: return to lobby, exit, and pause/resume. The separate full-width lobby-return bar is removed. All icons are original vector paths on a shared 24-point grid, with angular outlines matching the app's cut-corner controls. Lobby uses a house and return arrow; exit uses a door and outward arrow; pause switches to a play triangle while paused.

Returning to the lobby and exiting require a styled confirmation sheet with monospaced text and explicit consequences. Host exit closes the room for everyone; guest exit leaves that room; lobby return interrupts the game and returns everyone to the same room's lobby. Guests retain only their personal exit control. Cancel and sheet dismissal perform no action.

Confirmation is scoped to room, match, membership, actor, host authority, and room status. Stale confirmations are dismissed; confirming rechecks the current scope and lobby eligibility, then clears the confirmation before dispatch. Pending return remains disabled with a spinner; failed return retains its retry label and amber state. Existing backend handlers are unchanged.

The header remains visible and usable while paused, with underlying game controls disabled and hidden from accessibility. It no longer duplicates exit/lobby controls in the pause overlay.

## Validation

The signed `SupabaseDebug` build and installation identity checks passed. Native UI tests exercise header button size/alignment, host/guest visibility, both confirmation types, cancellation, pause/resume, and confirmed lobby return through the local preview handler. Existing FAN UI checks also cover 3, 4, 8, and 12 players and the separate player list. Final device results and screenshots are recorded in `release/evidence/game-header-214/`.

Final results: **10 test executions passed, 0 failed** across iPhone 17 (402×874 points) and iPhone SE 3rd generation (375×667 points), both iOS 26.5. Both confirmation actions and their Cancel buttons were visible and hittable without scrolling on both screens. Independent source review and `git diff --check` passed.

These are Simulator preview checks; no new live multiplayer or physical-device acceptance run is claimed. No backend deployment, TestFlight upload, or App Store publication was performed. Build metadata is synchronized to 214; marketing version remains 1.0.3.
