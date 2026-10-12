# Build 171 physical multiplayer checkpoint

Verified on 2026-10-13 Europe/London (server evidence uses UTC). The user asked
to stop further manual tests after automatic result recovery succeeded.

## Environment and clients

- Separate Supabase project `bbkfsgnordtdiblgdzkg`, `full-game-core` v2.
- Physical Ganzha: SpyClash TEST 1.0.3 (171), installed through TestFlight.
  The user confirmed launch; an app-container evidence read independently
  confirmed build 171 and protocol `full_game_core`.
- Two native Simulator clients, IOS2 and IOS3, built and launched on 171.
- Room `PDTZQG`, ID `3d6955a3-be0e-42ad-8ce5-a6fe883d00c2`; IOS1 was host.
- At the user's request, a private 12-word saved pack was created for IOS1 via
  its authenticated test API and read back. This was setup, not a substitute
  for native gameplay actions. No production generator request was made.

## Observed results

1. Three players joined through the original native interface. All three
   acknowledged their cards; the server then started the shared timer.
2. The host paused and resumed an initial match: revisions 42/43 recorded one
   pause interval of three seconds. The host returned to the lobby and started
   a new match at revision 45. These are server receipts; simultaneous paused
   overlays on both peers were not captured.
3. Match `05d94a34-6128-4336-8a8a-2be2c2aab713` completed a full associations
   turn cycle. IOS3 and IOS2 native actions committed at revisions 52 and 54;
   IOS1 completed the round at 56, with spin settlement at 57 and ROUND 02.
4. The user explicitly confirmed airplane mode plus Wi-Fi off on Ganzha.
   Both online Simulators requested voting and voted against IOS1. The match
   finished at revision 62 with winner `spy` on both native Simulator screens.
5. The server's room and Realtime signal both reached revision 62. It recorded
   exactly three per-player history rows and one `game_finished` outbox event
   for that match.
6. The user restored connectivity and confirmed that Ganzha displayed the
   same winning result automatically, without a manual refresh. A second
   phone-container export during the outage was unavailable because the
   device connection was lost. Recovery acceptance therefore combines the
   user's physical-screen observation with server and Simulator evidence;
   no post-recovery phone journal export is claimed.

## Limits and observed issue

- The planned offline READY/save/retry scenario was not performed: the user
  explicitly stopped further manual testing. Earlier protocol-level fault
  tests are separate evidence, not a replacement for that phone scenario.
- During Simulator A setup, a transient local pending-action guard displayed
  `[409]` while another action was unresolved. The exact UI text matches
  `SupabaseFullGameStore.recoveryRequired`, which is raised before transport.
  Joining subsequently succeeded. Preserved evidence does not establish
  whether the pending command was restored or newly in flight, and does not
  support a blanket claim that no HTTP 409 occurred.
- Both Simulators were left at FINISHED r62. No further phone actions, replay,
  production changes, or additional fault tests followed the stop request.

## Evidence

Sanitized native actions/receipts and server snapshots are retained in
`evidence/full-core-ios/build171-physical/`. Raw device snapshots, role-bearing
state, fixture credentials and configuration backups remain private in ignored
`.local` paths. TestFlight delivery is recorded separately in
`TESTFLIGHT-DELIVERY.md`.
