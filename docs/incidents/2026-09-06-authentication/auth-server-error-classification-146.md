# Authentication server-error classification — build 146 integration

Prepared locally on 2026-09-06 in `davidganzha/partner-bugfix-143`. This is an
additional runtime change after the build 145 authentication candidate was
staged. That existing candidate and its manifest do not contain this correction;
the integration owner must reconstruct and verify a new candidate before any
separately authorized deployment. No deployment, authentication configuration
change, or real sign-in was performed for this correction.

## Evidence and scope

The read-only production audit authenticated the CLI before querying only
`appleAuthBroker` and `googleAuthCallback`. The six-hour window beginning
2026-09-06 09:32:26 UTC contained eight log records for two Google callback
attempts, at 14:28:46 and 14:28:49 UTC. Both returned HTTP 400 with
`invalid_state` and `state_jwt_invalid`. The rejection occurred before the cookie
comparison. The window contained no separate cookie rejection, provider failure,
or Apple request. These records do not prove a fresh end-to-end sign-in attempt
or identify expiry as the sole cause; the production classifier also covered
other verification failures. No raw callback URLs, codes, tokens, or account
identifiers were retained in this audit document.

Source review established a separate reproducible classification defect:
`verifyBrokerJwt` loads broker keys before verifying credentials, and its callers
caught typed `BrokerError` service failures as though the supplied credential
were invalid. Missing key configuration or malformed public JWK therefore became
`invalid_state` (400) for Google and Apple state, `invalid_grant` (400) for token
exchange, or `invalid_token` (401) for userinfo. The Google browser recovery page
could consequently mislabel a server failure. Production occurrence of this
configuration failure was not established by the observed logs.

`appleAuthBroker/main.ts` now preserves typed server errors with status >= 500
before applying the existing credential-rejection policy. The same guard covers
Google callback and confirmation through their shared state verifier, Apple
callback, token exchange, userinfo, and the native-ticket authorize fallback.
Direct verification in native bootstrap already propagated the error and needed
no change. The existing response serializer emits the safe generic description
`Authentication service is temporarily unavailable`; internal exception messages,
environment variable names, and key values are not returned or logged.

Actual JWT expiry and signature failures retain their existing HTTP 400 handling.
No lifetime, signature, issuer, audience, cookie, redirect, provider exchange, or
authorization policy was relaxed. The guard recognizes the existing typed server
error; it does not guess error categories from messages or arbitrary objects.

## Verification

Two new actual-handler tests import a cold runtime with, respectively, missing
key ID and malformed public JWK. Each invokes six routes and requires HTTP 500,
the exact safe JSON body, no-store/no-referrer headers, no redirect, no provider
network calls, and sanitized service-error logs. The existing actual-handler test
also explicitly checks HTTP 400 for real expired and invalid-signature states on
both Google callback and confirmation.

```sh
/Users/davidganzha/.deno/bin/deno test --allow-env --allow-read --allow-net base44/functions/appleAuthBroker/ base44/functions/googleAuthCallback/
/Users/davidganzha/.deno/bin/deno check base44/functions/appleAuthBroker/main.ts base44/functions/googleAuthCallback/main.ts
```

Result: **67 passed, 0 failed** across both authentication function directories;
both runtime entry points type-check. The focused state/server-error subset was
**9 passed, 0 failed**. Formatting and scoped `git diff --check` passed. These
tests use ephemeral keys, injected environment values and intercepted network
calls; they do not validate production key configuration or real provider login.
