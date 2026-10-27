# Main Game Center server activation: 27 October 2026

This is the checkpoint-203 historical snapshot. The later investigation and
activation of ordinary full deletion are recorded in
[checkpoint 204](PUBLIC-DELETION-ACTIVATION-204.md); its readiness decision
supersedes the conservative global stop described below.

The signed client remains App Store 1.0.3 (200), source `da2e8584`. The backend
checkpoint is 203; this does not replace or re-upload the signed client.

## Completed and read back

- Main Supabase `bbkfsgnordtdiblgdzkg`: all four approved additive migrations,
  five private tables and their constraints. RLS/grants remain closed to clients.
- Three reviewed Edge dependency graphs deployed; the 202 app-services patch
  changes only the fixed deletion-provider route to `deleteAccountPublic`.
  JWT gateway checks remain true/true/false for app-services/core/Game Center.
  All 67 exported app-services source/import-map files match its 68-file payload;
  the export omits deno.lock. The four frozen engine/push/worker/policy files match.
- Twenty prepared configuration/credential values matched server digests; the
  four existing legacy settings were preserved. Private material is not in Git.
- Base44 original app `69a0e57fa939f578082f8091`: private receipt entity added,
  all 26 old schemas unchanged; managed AI function and separate
  `deleteAccountPublic` installed. The existing published `deleteAccount` and
  unrelated editor drafts remain in place.
- The new deletion route serves the prepared handler. A valid read-only signed
  archive probe matched the one bound historical Apple credential exactly.
  All 75 current/archive user identities were probed successfully. Twenty-five
  of 29 Apple rows are explained; four pending encrypted credential records have
  no immutable owner, alias or Apple-subject continuity. Expired binding tickets
  do not prove revocation. Independent review confirmed this blocker. The legacy
  full-deletion and Base44 archive-readiness flags remain false. This is a
  conservative global readiness gate, not evidence that all ordinary accounts
  own those four rows. The current per-request proof establishes authority over
  selected identifiers, but cannot certify that an unrecorded historical alias
  has no additional credential. No independently certified complete subset has
  been established, so enabling the global gate would overstate completeness.
- Approved maintenance job runs every minute, with public anon gateway token
  plus private worker header. Wrong header returns 401; empty work returns 200.
  Two scheduled HTTP200 responses were confirmed after access-boundary review.
  Hosted pg_net grants cannot be revoked: net is outside the API, client roles
  are NOLOGIN, exposed RPC/GraphQL has no queue bridge, and direct database roles
  are trusted infrastructure/admin. Vault is closed to API clients. No push
  delivery was enabled and no user deletion was performed by these checks.
- The policy at https://spyclash.com/privacypolicy was published with site-only
  deploy-dist. Exact retained live build 180 was rebuilt byte-for-byte before
  replacing one policy source file. All five resulting live assets match the
  reviewed archive; CSS/manifest and code outside the policy remain unchanged.
  Source HEAD and backend inventory stayed unchanged across this website action.
  Browser checks covered policy and Home to Apple/Google/email login controls.
- Accidental app `6adfe56fadd4564bb402fcbd` (SpyClash Copy) was moved to Recently
  deleted with the owner's approval; the UI offers recovery for 30 days.

## Verification and artifacts

The final checkpoint-203 combined source package passed 116 checks
(31+11+15+53+6), zero failures. Two unshipped engine cases remain intentionally
filtered. The route
change passed 25 focused database/auth/archive checks and independent review;
maintenance guards passed seven local PostgreSQL checks and independent review.

- Scoped alias archive SHA256:
  `7d503d69630416058c15a92b4c8dcdf32dc89a4af9b36fe0cc6179fde01574df`.
- Combined reproducible server archive SHA256:
  `a74ca62ca2553e6184d26151d96769999facf54ed5f35970b2b6197ca177daf8`.
- Published site-only archive SHA256:
  `17b92ffccf9d8237e4f8e4b5818285c537add2a864e7f9a4da0121c32d35e74c`.

Local sanitized receipts are under `.local/public-server201/activation`,
`.local/public-server202-alias`, `.local/public-server203-final`,
`.local/public-server203-relay`, `.local/public-server203-deletion-redirect`, and
`.local/privacy201-isolated-site`. Restricted credential/identity files beside
them are ignored, must not be printed and are not release artifacts.

## Runtime callback correction in checkpoint 203

The first signed Base44 relay probe stopped at `claim_transport` without an HTTP
response or a corresponding Supabase callback. The Cloudflare Workers runtime
does not support `redirect: "error"`; it rejects that request option before
sending. The existing relay now uses `manual`, with its existing non-2xx guard
rejecting every redirect. It neither follows Location nor retries paid work.
Diagnostics contain only fixed stage names and an optional numeric HTTP status.
See the [official Workers request documentation](https://developers.cloudflare.com/workers/runtime-apis/request/).

After the scoped function deployment, one signed missing-account probe at
14:54:08–14:54:12 UTC reached the fixed Supabase claim route. Supabase logged HTTP
403 on app-services version 15, request `01a17dda-b95d-7783-934d-e0693d6582c4`.
This is the expected rejection for the deliberately absent actor: the outer
Base44 result remains 503. Before/after account, assertion, generation-request
and provider-call counts remained zero. This proves the live authenticated
callback channel and its refusal boundary, not paid generation or device login.
All six deployed relay source files were read back exactly. Eleven focused
diagnostic/redirect checks and Deno type checking passed.

The same unsupported option was present in the prepared Apple revocation
module. Only that module was updated in `deleteAccountPublic`; all 15 deployed
source files match the reviewed payload. Manual redirects preserve the existing
unconfirmed/manual-revocation behavior, without forwarding the refresh token
or client secret. Six local tests cover HTTP200 and 301/302/303/307/308; the
original option fails the runtime-compatible negative control. Live read-only
checks return malformed400, unsigned403 and capabilities503, confirming the
readiness gate is still closed. No real Apple token was refreshed or revoked.

## Activation and remaining acceptance

Five native Game Center/IAP/AI flags are now true; 24 configuration digests match
including preserved legacy values and the false legacy-deletion flag. Native
Game Center account deletion uses its independent ownership path. The scheduled
maintenance runner remains active; ordinary full deletion in client 200 is not
ready for release while the four historical Apple records remain unexplained.
They were not deleted, revoked or reassigned.

The remaining historical evidence gap is the provenance of all Apple credential
writers/key generations and any administrative/provider identity reconciliation,
or an exhaustive per-account alias/credential journal. Ordinary `auth.updateMe`
cannot change email, so routine email editing is not an established explanation
for those four rows. Repeating the same 75-identity inventory cannot resolve the
gap. A future per-account readiness gate would need a complete ownership
certificate before irreversible provider deletion; the current code has no such
certificate. Do not infer ownership or purge the four records from ticket expiry.

Current runtime versions are app-services 15, full-game-core 11 and
game-center-session 3. Configuration changes increment runtime versions without
changing the verified source hashes. No real iPhone
Game Center login, sandbox purchase/restore, paid managed AI generation or real
account deletion is claimed. Apple processed client 200 as VALID and attached it
to 1.0.3; no App Review submission or public App Store release has occurred.
