# Build 196: automatic gameplay recovery and Radar regression

Date: 2026-10-21
Branch: `davidganzha/social-integration-192`
Baseline: `7b0faafb` (build 195)

## Report and cause

The reported GitHub run was https://github.com/davidganzha/SpyClash/actions/runs/39649526983.
Its client job failed one Radar test: a same-account profile refresh rebuilt a transport
that was still being constructed (`2` rebuilds instead of `1`). The backend job passed.

Separately, `SupabaseFullGameStore` retained an unresolved command after an ambiguous
network outcome, but periodic room reads never retried that journal. The UI required
`Retry saved action`; subsequent commands were blocked. The error toast could be
classified as success because its message contained `saved`.

## Resulting behavior

- Recovery starts automatically after a failed request, journal restoration, foreground
  activation and periodic reconciliation. The saved request ID and payload remain unchanged.
- A recovery burst uses 0.4/1/2/4 second backoff; server cooldown values are honored.
  Longer outages resume through the existing reconciliation cycle without overlapping writes.
- Identical concurrent and queued taps share one operation. A different command waits
  for the preceding request and cannot silently move into a changed room/match/turn.
- A replayed successful room receipt is followed by an authoritative read before its
  projection can be displayed. A removed membership is not restored from an old receipt.
- Account/connection changes fence delayed responses; definitive rejections clear the journal.
- The recovery button is replaced by a localized passive connection status. Background
  word-pack completion is scoped to the editor's original request and unchanged draft.
- Radar profile refresh and foreground activation preserve an in-progress transport build.

## Validation

- Native conflict/auth suite: 179 passed, 0 failed, 1 existing skip.
- Native saved-action/isolation suite: 30 passed, 0 failed, 0 skipped.
  This includes 16 added recovery regressions, for 29 adapter tests plus one isolation test.
- Native Supabase session/legacy-upgrade suite: 54 passed, 0 failed, 0 skipped,
  including the HTTP failure classification and server cooldown regressions.
- Offline backend conflict gate: 786 passed; 4 additional Python checks passed.
- Offline auth gate: 83 passed, with 33 nested steps; no failures.
- Swift parse, shell syntax, whitespace and synchronized build-number checks passed.
- Actual XcodeGen regeneration verified that the unit-test-only `LAB_CONFIG_PATH=/dev/null`
  override survives generation; the normal lab app launch is unchanged.

The final saved-action result bundle is `test_sim_2026-10-21T22-40-14-780Z_pid94628_efe814fa.xcresult`.
The conflict/auth result bundle is `test_sim_2026-10-21T22-34-33-329Z_pid94628_b5d6b874.xcresult`.
The Supabase session result bundle is `test_sim_2026-10-21T22-41-04-740Z_pid94628_2684a56e.xcresult`.
They are under the local XcodeBuildMCP `SpyClash-f8b83e29e9ef/result-bundles` directory.
Offline gate logs are `/tmp/SpyClash196-backend-conflicts.log` and `/tmp/SpyClash196-backend-auth.log`.

During validation, the older isolation test lacked the current Apple handoff argument;
the fixture now asserts that handoff is never reached. Its initial dependence on a
Simulator's saved lab account was removed by the test-only configuration override.
The final 30-test run passed after these fixture corrections.

## Delivery boundary

Build number is 196 in both project sources; marketing version remains 1.0.3.
This checkpoint changes the client and regression coverage. No server implementation,
schema, production configuration, App Store or TestFlight release is part of it.
Physical two-phone gameplay and the original reporter's acceptance remain separate
from the deterministic Simulator/network-fault tests. Numeric `Retry-After` is supported;
HTTP-date retry headers are not interpreted by this client.
