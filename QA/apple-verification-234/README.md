# Apple purchase verification repair (234)

The user reported `IAP-BUY-SERVER-NONE: HTTP_422` in TestFlight. The native client receives a successful, locally verified StoreKit transaction, then fails while synchronizing it with the server. `NONE` is the immediate-purchase source label, not a missing transaction.

## Incident evidence

Read-only inspection of Supabase project `bbkfsgnordtdiblgdzkg` found six HTTP 422 responses from `app-services` v23 on 2026-11-11 at 23:03:50.592, 23:04:34.608, 23:05:07.961, 23:05:31.702, 23:05:38.577, and 23:06:14.231 UTC. The screenshot was taken at 23:05:40. The two immediately preceding failures identify `SpyClash/232` in the user agent. No failed transaction receipt was persisted during 23:03–23:07.

The deployed verifier collapses non-retryable Apple SDK exceptions, including unsupported server crypto primitives, into `invalid_apple_transaction` / 422. Its handler does not log the nested exception; the precise nested cause of the user's request is therefore unavailable. A local reproduction using the actual pinned Apple SDK and official Supabase Edge Runtime deterministically fails before signature validation because the runtime's X509 methods are unimplemented. See [runtime reproduction](runtime-reproduction.md).

The app leaves the StoreKit transaction unfinished until server acknowledgement, allowing reconciliation after the server repair. No charge, purchase, restore, entitlement grant, production configuration change, or deployment was performed during this investigation.

## Scope

The repair supplies the missing certificate operations while retaining Apple's original verifier, online certificate revocation checks, signed payload checks, explicit environment gates, canonical App Store subscription lookup, and account ownership rules. Known runtime failures receive a retryable 503 instead of a false invalid-purchase 422; diagnostics use a closed vocabulary without payloads, credentials, URLs, or account identifiers.

The signed-fixture tests also exposed Apple's 3.1.0 OCSP date parser accepting stale responses because trailing-`Z` timestamps become `Invalid Date`. A strict UTC/calendar parser is installed on each pinned verifier instance; the existing OCSP signature, signer, status, certificate-ID and clock-skew checks remain active. EC key curve names are normalized only after comparison with the native public JWK's actual curve. No private key material is exported.

The local source branch is based on build 233. The synchronized project build number is 234; marketing version remains 1.0.4. No Swift purchase behavior is changed.

The prepared hosted candidate must be derived from the downloaded v23 bundle in [live baseline](live-baseline.json), with only the verification repair overlaid. The newer local branch contains other server changes that are outside this incident and must not be deployed with this repair. The candidate manifest and patch identify the exact approved scope.

## Validation

- 20 signed-fixture scenarios passed in the actual official Supabase Edge Runtime 1.70.5/Deno 2.1.4: [result](edge-regression-results.json). They include valid Sandbox and Production transactions with online DER OCSP, invalid app/signature/root/purpose/expiry/algorithm/curve, revoked/unknown/stale/forged OCSP, retryable network failure, safe diagnostics, and native App Store API bearer signing. Fixtures use disposable in-memory keys and a local test CA, never a production trusted root.
- 22 existing native billing and loyalty tests passed against isolated local PostgreSQL, including ownership, renewal/refund, deletion races, fail-closed behavior, and environment selection.
- 20 signed SDK scenarios also pass in ordinary Deno and with emulated missing runtime methods; two policy tests verify retryable failure classification, diagnostic redaction, and strict calendar parsing. [Reproduction commands](../../experiments/supabase-game-core/tests/app-services/apple-verifier-runtime.md).
- The full local `app-services/index.ts` and the exact minimal v23-based hosted candidate both pass strict Deno type checking. Git whitespace validation passes.
- The project build values are synchronized at 234; the iOS app was not rebuilt or uploaded because its purchase implementation did not change.
- Independent review found no actionable security issue in the compatibility adapter or per-instance OCSP parser.

The minimal candidate has 77 files: the original 74, one modified verifier module and three new compatibility/diagnostic helpers. See [candidate manifest](candidate-manifest.json) and [reviewable patch](candidate.patch). No changes to secrets, database schema, account bindings, subscription products, or rollout flags are included.

## Deployment boundary

Production publication requires fresh explicit approval for replacing **Supabase `app-services` in project `bbkfsgnordtdiblgdzkg`**. Before publication, re-read the hosted source and compare it with the recorded v23 baseline. Stop and rebase the repair if that baseline has changed. A GitHub push or successful local test is not production approval.

Successful local signed-fixture validation does not prove that the user's real transaction has been accepted. After an approved deployment, restore/reconciliation on the user's TestFlight installation remains the acceptance check.
