# Generation library recovery — build 231

Status: **both server fixes were published on 11 November 2026 after explicit confirmation in this chat.** Supabase `app-services` is ACTIVE at version 22, and Base44 `generateWordPack` matches the approved candidate. No configuration change, paid live generation, or TestFlight upload was performed.

## Incident and cause

The screenshot's 503 matches the legacy generation route. At 20:41:16 UTC on 11 November 2026, Base44 `generateWordPack` logged `Word library is temporarily unavailable. Retry this request.` Supabase retained a legacy reservation created at 20:41:15. The iOS mutation journal then rejected the change from 40 to 12 words locally with `app_action_recovery_required`; that 409 never reached the server.

The deployed shared-library REST adapter used `redirect: "error"`. Base44's Workers runtime rejects that mode before sending a request. Supabase gateway logs contain no library RPC during the incident, consistent with this failure. The same runtime incompatibility was previously corrected in the native relay by commit `89625a093bc2ad9cad74d44f389611b0cd464c77`. [Cloudflare's Request documentation](https://developers.cloudflare.com/workers/runtime-apis/request/) describes the restriction and the supported manual mode.

The legacy bridge also discarded the explicit pre-effect retry metadata, replacing it with a generic error that the installed build's automatic library-retry policy did not recognize. A separate native self-audit failure at 20:41:08 was refunded and is not the source of the screenshot's legacy error; later native requests succeeded.

## Changes

- The Base44 library adapter uses manual redirects and rejects every non-2xx response. It never follows redirects or forwards its credential to another destination.
- The Supabase bridge forwards only the two recognized library 503 codes with complete proof that effects have not started. Unknown, partial, malformed, and ambiguous responses remain conservative. The exact definitive quota 429 code is preserved separately, so an exhausted allowance does not strand a request after the allowance changes.
- iOS preserves the original request ID after ambiguous conflicts, throttling, timeouts, or retryable failures, and checks account scope before processing an error. Known definitive quota failures still release the journal entry.
- `CURRENT_PROJECT_VERSION` is 231 in both project files; marketing version is unchanged.

## Verification

All providers and generation responses used by the tests are fixtures. Database tests use loopback PostgreSQL (`127.0.0.1:56322`).

| Check | Result | Evidence |
| --- | --- | --- |
| Library, REST, retry contract | 39 passed | `base44-library-tests.log` |
| Actual Base44 handler regression | 16 passed | `base44-handler-integration.log` |
| Legacy bridge parser and database integration | 19 passed | `backend-bridge-tests.log` |
| Signed iOS Simulator generation/journal tests | 14 passed, none skipped | `ios-tests-summary.json` |
| Exact Base44 and Supabase deployment candidates | Type checks passed | `*-candidate-typecheck.log` |

**88 tests passed.** The library suite's first invocation omitted local read permission; it was rerun with `--allow-read` and all 39 passed. The final Simulator result is `/tmp/spy-generation231-client-final-tests.xcresult`. No real-device or production-generation acceptance is claimed.

## Verified production deployment

`candidate-manifest.json` records the reviewed live baseline and file hashes. Local candidate and rollback packages are under `.local/generation-library-recovery/` in this worktree. Exactly two runtime files differ:

1. Base44 app `69a0e57fa939f578082f8091`, function `generateWordPack`: `shared-word-pack-rest.ts`.
2. Supabase project `spyclash-game-core` (`bbkfsgnordtdiblgdzkg`), function `app-services`: `legacy.ts`, over the fetched live version 21 with JWT verification preserved.

Fresh preflight reads matched the reviewed baseline for both functions. All other live runtime files were preserved. No migration, secret change, quota/ad flag change, or native relay publication was performed.

- Supabase publication returned ACTIVE version **22**, with JWT verification enabled. All **74** downloaded runtime/configuration files match the approved deployment payload.
- Base44 publication reported **1 deployed**. All **18** downloaded runtime files match the approved candidate.
- Both unauthenticated generation-route probes returned **401** before generation work.
- Receipts and comparisons are recorded in `supabase-deployment.json`, `base44-deployment.json`, and `unauthenticated-postdeploy-check.json`. Source snapshots remain under `.local/generation-library-recovery/preflight/` and `postflight/`.

This verifies publication, exact source contents, and authentication rejection. The affected device's real generation has not been replayed by the agent; it remains the final user acceptance check.

The server changes support the existing build 230's retry behavior. The separate iOS journal-hardening change requires a future application build and is not part of server publication.

## Existing saved request

The affected device must now retry the original theme and 40-word count to settle its saved request. Changing to 12 while that original intent remains unresolved still produces local 409. This patch does not silently discard a potentially charged result or add manual recovery controls. Automatic recovery across changed inputs would require durable delivery of the old result and is not implemented here. Do not delete the user's app data or server request history to bypass the journal.
