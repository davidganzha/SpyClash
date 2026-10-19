# Radar invitation responsiveness — build 188

Baseline: `4971d79a`, build 187, branch `davidganzha/supabase-game-core`.
Scope: invitation carousel stalls and failed Radar invitations. No production changes.

## Code-derived workload and timing

- A Radar page exit synchronously stopped one browser, disconnected one MCSession, invalidated each ranging/probe session, and paused the shared ARSession on MainActor.
- Normal discovery admits six automatic control peers, with a seventh remote session slot reserved beyond that normal fan-out. Each eligible peer can have a ranging session; one ARSession is shared.
- Ranging publication is capped at 12 Hz per peer. Six peers can therefore produce 72 measurement-driven updates per second to the array observed by the lobby, although its invitation cards display no distance/bearing.
- Presence connections use 10-second framework / 11-second app timeouts; legacy ranging uses 15/16 seconds. An explicit invitation can queue behind an already running connection attempt. A tap 4–6 seconds into an 11-second attempt can wait another 5–7 seconds before fallback; this is a possible timeline, not measured attribution of the reported freeze.
- Direct room connections use 15 seconds; the app response timeout is 18 seconds. The prior response retry was only 14 × 120 ms = 1.68 seconds of sleeps. Direct invitation context could be processed before the encrypted connection was ready.

## Changes

- Serialize Multipeer creation/start/stop/invite/send/accept off MainActor; retire generations immediately and reject cancelled or superseded queued room invitations.
- Use a separate serial queue for NI/AR run/invalidate/pause so camera operations cannot hold up invitation sends. Retired sessions cannot be installed by a stale asynchronous construction completion.
- Start timeout budgets after their queued framework operations. Preserve encrypted connections and existing permission gates.
- Hold direct incoming invitation contexts until `.connected`, clear them on cancellation/disconnection/transport retirement, and bound transient response retries to 18 seconds with a transport-generation guard.
- Publish `directoryPeers` only when card identity/content/order/count/policy/availability changes. All 16 view consumers use this projection. Measurement-only changes produce zero directory publications; live measurements remain internally available.
- Build number 187 → 188 in both version sources; marketing version remains 1.0.3.

## Validation

- Generic iPhone `build-for-testing`, `SupabaseDebug`, code signing disabled: passed, including compilation of the new and adjusted XCTest cases. This compiles tests; it does not execute them.
- Host Swift 6 checks compiled the executor/lifetime and directory comparison directly extracted from the current source: 1,000 cancelled queued operations skipped; replacement operation ordering preserved; MainActor continued while the framework worker was blocked; transport progressed while a separate hardware queue was blocked; 720 measurement changes preserved directory content while policy/availability/name changes invalidated it.
- Independent review checked retirement, queued cancellation, timer ordering, direct-context delivery, and all directory view consumers; identified concerns were addressed.
- `git diff --check`: passed.

No Simulator checks were performed after the user requested code/numeric analysis. Earlier baseline Simulator exploration did not reproduce the reported 5–7-second stall and is not acceptance evidence. The nearby physical iPhone's lightweight XPC diagnostic had no app/Multipeer/NI/AR frames and did not identify this hang.

Remaining evidence boundary: the corrected build has not been installed or exercised on two physical iPhones, and no before/after phone timing is claimed. NISession construction/discovery-token access and configuration construction remain on MainActor; the patch removes the identified explicit blocking calls, not every possible OS-level stall. Pending invitations still follow the existing cancellation-on-leaving-Radar behavior. Backend, TestFlight, and App Store state were not changed.
