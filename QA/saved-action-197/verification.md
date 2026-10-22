# Build 197: WebKit regression-runner follow-up

Date: 2026-10-22
Branch: `davidganzha/social-integration-192`
Baseline: `ed0ad025` (build 196)

Build 196's automatic saved-action recovery and Radar fix remain unchanged.
Their implementation and local verification are recorded in `../saved-action-196/verification.md`.

## Exact-head CI finding

Run https://github.com/davidganzha/SpyClash/actions/runs/39688453733 passed the backend
job and all 93 `Base44ClientRoomActionTests`, including the reported Radar regression.
It failed an existing WebKit navigation-policy fixture: the cold WebContent process
took 23.668361 seconds to launch, exceeding the fixture's combined 15-second deadline.

The fixture now waits separately for a document-ready signal (45-second startup
deadline), then initiates the forbidden navigation and retains the 15-second policy
deadline. It asserts the exact navigation-policy error, one completion, no callback,
and that the rejected URL never loads. Startup or unrelated errors cannot satisfy
the rejection assertion. The first client test stage runs serially, consistent with
the two Supabase stages, to reduce concurrent WebContent startup pressure.

## Validation

- Full native WebKit suite on build 197: 18 passed, 0 failed, 1 existing skip.
- Result bundle: `test_sim_2026-10-22T07-48-54-234Z_pid94628_705b5bd3.xcresult`
  in the local XcodeBuildMCP `SpyClash-f8b83e29e9ef/result-bundles` directory.
- The tool response timed out; the completed Xcode result bundle was independently
  read with `xcresulttool`, which reports `Passed` and the counts above.
- Shell syntax, whitespace and synchronized version checks passed.
- The recovery/auth/backend checks from build 196 are historical evidence for the
  unchanged runtime code; they were not repeated as new build-197 local runs.

Build number is 197 in both project sources; marketing version remains 1.0.3.
This follow-up changes test infrastructure only, in addition to the required build
number. It does not deploy a server, publish TestFlight, or validate two physical phones.
