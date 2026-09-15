# Recurring account-wide 409 after room lease cleanup fails

Status: **deployed on 2026-09-15; exact production postflight verified**.
See `deployment-receipt.json`. The user confirmed the exact two-function scope
immediately before this deployment.
Source branch: `davidganzha/fix-recurring-409-release`, based on `346045e`.
Bookkeeping version: iOS `1.0.1 (156)`; no new iOS artifact was built or installed.

## Observed failure

Read-only inspection of canonical SpyClash app `69a0e57fa939f578082f8091`
found this sequence on **2026-09-12 UTC**:

- At 16:18:05, `gameRoomAction` logged three
  `Billing lifecycle lease release could not be reconciled` errors after a
  committed action, all with code `ambiguous`.
- From 16:18:19, typed `active_lease` errors affected lobby edits, room closure,
  joining, creation and leaving. Generation and push requests also returned 409.
- The captured 418-entry incident sample contains 58 game, 12 generation and
  59 push HTTP 409 responses. The sample is not a complete traffic census.
- A read-only lifecycle query at 2026-09-14 22:12:53 UTC returned 98 records and
  zero unexpired leases. No account locks were cleared manually.

The deployed room code matches the source before this change. Its three outer
release attempts contain three immediate storage attempts each, separated only
by 25 and 50 ms outer waits. A short storage failure during cleanup exhausts
these retries; the successful business result survives but a ten-minute account
lease can remain. The log discards the underlying storage error, so it does not
establish whether the initiating failure was a timeout, throttling or another
service error.

Separately, deployed `generateWordPack` has an older lifecycle helper that lacks
cleanup for an acquired-but-unconfirmed lease. The current source already fixes
this. This drift is a second defect, not proof that generation caused the
observed three-account room cleanup failure.

## Change

- Retry failed room lease releases in shared rounds with delays of 250, 750 and
  1500 ms. Every participant receives an initial attempt; only unsuccessful
  owners are retried, with at most four releases in flight.
- The deliberate wait budget is 2.5 seconds **per helper invocation**, independent
  of the number of participant batches. Storage request time is additional;
  this is not a wall-clock or whole-request deadline.
- Preserve the original exact lease ownership comparison, deletion protection,
  completed result and original action error. The business action is never
  replayed, and every started cleanup is awaited.
- Restore the already-tested current lifecycle helper in `generateWordPack`.

Long storage outages and a killed/suspended runtime can still leave a lease until
expiry. This patch does not establish immunity to all 409s or change semantic
conflicts such as stale lobby revisions.

## Exact deployment candidate

The fresh read-only snapshot contains 17 functions and 195 runtime files.
The two selected functions contain 61 runtime files. Exactly two files change:

| Function | Runtime module |
| --- | --- |
| `gameRoomAction` | `room-write-lifecycle.ts` |
| `generateWordPack` | `billing-identity-lifecycle.ts` |

All other runtime bytes and normalized function configurations are preserved,
including the deployed generation entry, provider, membership policy and word
normalization. This matters because the current source and deployed generator
also differ outside the approved repair. Deploying either working checkout
directly would include those unrelated differences.

`candidate-manifest.json` records all baseline and candidate hashes, exact
source hashes and function configuration hashes. `runtime.patch` contains the
two reviewed diffs. The local-only preparation command is:

```sh
python3 docs/incidents/2026-09-15-recurring-409/prepare-candidate.py \
  --baseline-root /absolute/path/to/fresh-pull \
  --output-root /absolute/path/to/new-candidate
```

It rejects baseline drift, a different app binding, changed source inputs and
existing output directories. It reuses the existing exact inventory verifier.
No schema, secret, auth setting, website, purchase or App Store change is needed.
Fresh explicit approval is required before deploying only these two functions.
Immediately before deployment, verify another fresh full baseline against the
manifest; after deployment, verify all 17 functions against candidate hashes.

## Validation

- New real-lifecycle fault tests for shared outages of 100, 900 and 2000 ms all
  fail against the original wrapper because subsequent acquisition returns
  `active_lease`. All three pass after the repair with six participants.
- The candidate's 66 focused tests pass, covering lifecycle ownership, partial
  acquisition cleanup, persistent failure, replacement/deletion owners,
  bounded group waits, successful-owner exclusion and response completion.
- The two complete source function suites pass: 507 tests and 13 steps.
- `deno check` passes for both exact staged production entrypoints.
- The manifest accepts the 61-file candidate and rejects modified runtime bytes
  and a different app binding. Bundle isolation and `git diff --check` pass.

Tests use fake storage and make no production mutations. Real authenticated
two-client gameplay remains unverified.

## Production deployment on 2026-09-15

- A new full read-only pull matched all 17 functions / 195 runtime files in
  the approved baseline. The isolated candidate was reconstructed and verified.
- At 11:54:29 UTC, Base44 CLI 0.1.0 began the named two-function deployment.
  Both functions reported deployed; CLI exit status was zero by 11:55:39 UTC.
- At 11:56:01 UTC, an independent fresh pull matched the exact candidate hashes
  for all 17 functions and 195 runtime files. Only the two approved modules
  differ from baseline. All function configurations and 15 unselected functions
  remain unchanged.
- The short log window 11:54:29–11:55:40 UTC contained no requests for the two
  functions. This is not evidence of successful gameplay.
- The read-only postflight lifecycle count and timestamp are recorded in the
  receipt. No account lock or data record was manually changed.
- No schema, website, secret, auth setting or App Store operation was performed.
