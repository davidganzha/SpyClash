# Online intro rework — build 209

Based on `e7fc84dd` (build 208) in the isolated `davidganzha/online-intro-209` branch.

The old three-second intro reused an eight-second avatar/checkmark sequence. Its spring reached the clamped endpoint in about 15% of each card flight. The new presentation uses one smooth, locally timed card formation, two restrained haptic accents, a localized mission pulse, and a fade through black into a prepared role card.

## Timing and behavior

- Menu cover: 0.34 seconds, including shell controls fading in place.
- Deck emergence: 0.24–0.66 seconds.
- Radial spread settles by 1.755 seconds; mission reveal 1.62–2.10 seconds; pulse settles by 2.52 seconds.
- Existing server intro duration remains 3 seconds with its 0.2-second completion margin and legacy-server fallback unchanged.
- The 0.45-second departure fades the mission to black, then reveals the settled gameplay surface. It may begin at local 2.55 seconds if authoritative gameplay is already available. Normal preview completion arrives at 3 seconds and reveals the card by approximately 3.45 seconds; network delay can extend the composed hold.
- Local visual time prevents delayed server snapshots from skipping the opening. Account/room/intro scoping prevents stale completion tasks from hiding a newer sequence.
- Direct gameplay joins skip the intro. Reduce Motion uses a static formation and opacity changes. The completed timeline stops redrawing.
- Removed unused duplicate intro rendering and start-success toasts that interrupted the dissolve. Errors retain their existing feedback path.

## Verification

- Signed Debug Simulator build succeeded. The repository installer validated the signature, Keychain identity, and installed contents on the isolated `SpyClash Intro 209 QA` Simulator (iPhone 17, iOS 26.5).
- 17 selected unit tests passed: 10 presentation lifecycle tests, 3 motion regression tests, and 4 existing server-start contract/cancellation tests.
- 2 UI tests passed on the final implementation: menu → intro → usable role card; completed Ukrainian composition with 12 players while the destination is held.
- Final UI result: `test_sim_2026-11-05T20-38-46-640Z_pid34160_b1e7c9f6.xcresult` under the local XcodeBuildMCP result-bundles directory.
- Unit result: `test_sim_2026-11-05T02-19-02-742Z_pid34160_f4028366.xcresult`.
- Manually inspected recorded Russian transitions and English/Spanish 12-card compositions. Verified Reduce Motion at progress 0.4 and 1; restored the isolated Simulator's preview preferences afterwards.
- Initial UI runs on a shared Simulator were contaminated by another preview, then a transient-state test missed its observation window. Final tests use a dedicated Simulator and a deterministic held-state fixture.
- Live multi-device online sessions, physical-device frame pacing, haptics, and TestFlight acceptance remain unverified. No backend or production release action was performed.

## Preview

Launch arguments for a local, network-free menu → intro → role-card preview:

```
--spyclash-ui-preview --spyclash-preview-tab=game --spyclash-preview-room=waiting --spyclash-preview-lang=ru --spyclash-preview-intro-transition
```

For a held frame, use `--spyclash-preview-room=roulette --spyclash-online-intro-progress=1`. Player count supports `--spyclash-preview-player-count=12`. `--spyclash-preview-intro-delay=4` adds four seconds to the preview destination delay without changing the animation.

Final local video: `/Users/davidganzha/.codex/visualizations/2026/11/05/01a1a975-e5ce-7af2-9ff5-6b19439e32ae/online-intro/SpyClash-209-final.mp4`.
