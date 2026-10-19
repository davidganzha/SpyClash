# Immediate Radar invitation dispatch — build 190

Baseline: `dc5bd528`, build 188. Scope: remove the explicit invitation's dependency on an existing presence/ranging connection attempt. No production or Simulator actions.

## Behavior and timing

- Previously the tap stored the room invitation until the active background connection succeeded or its 11-second (presence) / 16-second (legacy ranging) watchdog expired. A tap 4–6 seconds into a presence attempt could therefore wait another 5–7 seconds before direct dispatch.
- Now a connected peer gets a reliable room message immediately. Otherwise the tap queues the direct room-invitation context immediately, regardless of background presence/ranging/connecting state. No background watchdog is awaited.
- If a reliable send loses its connection, it falls back to the direct context immediately even when the framework's connected-peer snapshot is stale.
- The same invitation ID and message remain available for reliable delivery when the session connects. Receiver deduplication prevents a repeated invitation prompt.
- A background `.notConnected` callback cannot mark the active room invitation unavailable. Direct dispatch is bounded to the initial attempt plus one retry; further callbacks do not start additional invitations.
- One 18-second response deadline starts before dispatch for each tap. Connection/retry callbacks never restart it. Each framework invitation is capped at 15 seconds or the remaining response budget, whichever is shorter, including queue time at execution. Reliable sends also check this deadline when the worker executes them.
- This deadline is a failure/response budget, not a delay before sending. Actual discovery, radio transmission, encryption, and user response still take time; no physical-device latency is claimed.
- Cancellation, account/transport retirement, terminal peer removal, and blocked/busy policy changes clear delivery state and cancel queued invitation work.

## Verification

- PASS: generic iPhone `build-for-testing`, `SupabaseDebug`, code signing disabled. Includes compilation of four updated delivery-policy XCTest cases; XCTest execution is separate.
- PASS: `python3 QA/radar-invitations-190/check_dispatch.py` extracts six production methods and six declarations into a host Swift 6 harness with fake transport boundaries. All 8 background-state combinations dispatch during the tap call; 160 repeated failure/retry requests stay capped at two direct attempts with the same ID and deadline; 8 cancellation/replacement cases reject old IDs. Connected-send failure falls back immediately; the deadline exists before either connected-send outcome; a retry with two seconds left gets at most that budget; an expired retry cannot dispatch. This exercises source dispatch/control flow without iOS, Simulator, network, or real invites.
- PASS: whitespace checks and independent review. Review covers background failure races, bounded retries, unchanged invitation IDs, cancellation, and fixed deadlines.

The fix was developed in an isolated checkout to avoid unrelated concurrent community-screen changes. Backend, installed iPhones, TestFlight, and App Store state were not changed.
