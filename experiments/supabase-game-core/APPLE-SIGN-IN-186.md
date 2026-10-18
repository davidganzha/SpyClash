# SpyClash 1.0.3 (186): bind the native Apple session candidate before acceptance

18 October 2026. Based on build 185 delivery checkpoint `db21352d`, branch `davidganzha/supabase-game-core`.

## Physical report and diagnosis

The user tested delivered build 185 on a physical iPhone at approximately 01:32 London time and reported `SCA177-H34-r6-s0-cN-uOT-q12-pN-fN`. Build 185 did not restore Apple sign-in. The code identifies a sixth main-document navigation to an unclassified path on a canonical trusted HTTPS host, with `access_token` and other metadata, without `auth_provider` or a fragment. It does not reveal the exact path, other parameter names, or token identity.

Read-only broker logs around 00:32 UTC show successful native exchange, bootstrap, authorization, token and userinfo requests. A fresh credential-free SSO probe also preserves the exact configured `from_url` through the provider state. Neither observation proves the final Base44 route. Public SDK/frontend/schema inspection did not establish that route; the implementation therefore does not add a guessed path to the document allowlist.

## Change and acceptance boundary

The isolated, unpresented WebKit session recognizes an **unverified token candidate** only after its owned main-document sequence reaches the fixed SSO callback through login and broker authorization. Candidate navigation requires the main source and target, GET, no download, canonical HTTPS on an existing trusted host, no fragment, unique bounded query names/values, and no conflicting provider/error payload. The candidate URL is canceled before any request or document rendering. All metadata and the original path are discarded; an internal fixed callback carries only the token through the existing coordinator.

That normalization is transport plumbing, not authentication. A separate typed native Apple acceptance entry point requires the original nonempty binding ticket and explicit `autoRegisterUserV2` success before session exchange or commit. The server verifies the candidate identity against the Apple-verified identity and any existing account owner. Attempt ownership, task cancellation and session generation are checked before acceptance and again before the Supabase exchange. An omitted ticket cannot silently select the generic provider registration path.

The binding proves account identity, not that a token was minted by this exact SSO transaction. The existing account model links a first binding through Apple-verified email and subsequently enforces the existing owner. Replaying a completed binding for the same owner is intentionally idempotent. The generic backend still permits registration without a binding ticket; the native Apple entry point now rejects that omission before making a request.

The document allowlist, strict canonical callback parsing and Google transport remain intact. No visible browser or browser fallback is added. No backend, website, identity mapping or billing configuration is changed. Both project version definitions advance to 186; marketing version stays 1.0.3.

## Evidence

- The new staged-WebKit regression fails against the unchanged build 185 session with the same `H34-r6-s0-cN-uOT-q12-pN-fN` structure as the phone report. The tested path/token are synthetic, not a captured production URL.
- **82/82 focused native authentication tests pass**, including policy validation, real-WebKit ownership, Apple candidate acceptance, missing/invalid binding, malformed V2 responses, cancellation, stale attempts and shared Google behavior.
- A separate **real CONNECT/TLS/HTTPS test passes in both modes**: five server redirects ending on SpyClash, and four redirects plus a JavaScript completion ending on Base44. Each makes exactly five fixture requests and **zero requests to the token-bearing landing page**. Production WebKit navigation/challenge delegates are used unchanged. The fixture never forwards network traffic. Its test CA was installed only in a new disposable Simulator; that Simulator and both temporary certificate/key directories were deleted afterward.
- The first tool-driven HTTPS run skipped because the tool did not pass test-runner environment variables. Both subsequent command-line runs executed and passed; that skip is not counted as successful coverage.
- Offline backend validation passes **29/29 credential tests and 17/17 V2 contract steps**, with network and environment permissions denied. Wrong identity/owner and invalid pending bindings are rejected; new-user negative cases assert zero invitations.
- The compiled Supabase variant passes **3/3 targeted tests** for preserving the original Apple binding ticket in the V2 request, rejecting unverified V2 responses without fallback, and retaining the existing Google registration route. These mock-transport tests do not establish hosted Supabase exchange or device acceptance.
- The **SupabaseRelease unsigned archive passes 19/19 checks**: app/widget 1.0.3 (186), canonical identifiers, unchanged backend configuration, arm64, only the expected extension, no test/mock/StoreKit artifacts or distribution signature. The audit records current production-source hashes and source modification times preceding the archive; no separately captured before/after cryptographic source freeze is claimed.

Sanitized receipts are in `evidence/full-app/build186/`; ignored logs and result bundles are in `.local/apple186-no-browser/`. The reproducible HTTPS fixture is in `scripts/tests/fixtures/`.

## Delivery boundary

After a separate explicit approval in the current chat, the exact source commit `3fdd43eee82e8bfedcd704faf5529b2b0cb0dfc3` was distribution-signed and delivered as 1.0.3 (186) to TestFlight Internal Only. App Store Connect verified the build ready for internal testing at 22:23:28 UTC / 23:23:28 London on 18 October 2026, assigned only to the existing private group containing David Ganzha and Dima Ianushevych. See [RELEASE-186.md](RELEASE-186.md) and the sanitized delivery receipt for the signed-artifact and audience checks. Successful Apple sign-in and prior-account continuity on the physical iPhone remain unproven. No backend or website deployment was performed during preparation or delivery.
