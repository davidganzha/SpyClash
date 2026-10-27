# Main Game Center server activation: 27 October 2026

The signed client remains App Store 1.0.3 (200), source `da2e8584`. The backend
checkpoint is 202; this does not replace or re-upload the signed client.

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
  Coverage/readiness is still being reconciled; flags remain off until it passes.
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

The final combined local source package passed 99 checks (31+11+15+42), zero
failures. Two unshipped engine cases remain intentionally filtered. The route
change passed 25 focused database/auth/archive checks and independent review;
maintenance guards passed seven local PostgreSQL checks and independent review.

- Scoped alias archive SHA256:
  `7d503d69630416058c15a92b4c8dcdf32dc89a4af9b36fe0cc6179fde01574df`.
- Combined reproducible server archive SHA256:
  `acb8f7a80626c20d093b13ba7251ab91abd73bdc60b4980f277c59c9e0d7fdbf`.
- Published site-only archive SHA256:
  `17b92ffccf9d8237e4f8e4b5818285c537add2a864e7f9a4da0121c32d35e74c`.

Local sanitized receipts are under `.local/public-server201/activation`,
`.local/public-server202-alias`, `.local/public-server202-combined`, and
`.local/privacy201-isolated-site`. Restricted credential/identity files beside
them are ignored, must not be printed and are not release artifacts.

## Remaining acceptance

Final historical coverage and feature activation are pending. No real iPhone
Game Center login, sandbox purchase/restore, paid managed AI generation or real
account deletion is claimed. Apple processed client 200 as VALID and attached it
to 1.0.3; no App Review submission or public App Store release has occurred.
