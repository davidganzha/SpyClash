# Direct native Apple sessions

`POST /functions/v1/apple-session` accepts only `identity_token`,
`authorization_code`, `raw_nonce`, `request_id` (UUID), optional `given_name` and
`family_name`. The iOS AuthenticationServices request sends SHA-256(raw_nonce)
to Apple. Never retry an authorization code, nonce or request ID; begin a fresh
native authorization after a failed attempt.

The response contains `provider: "apple"`, standard Supabase access/refresh
tokens, expiry, `user: {id}` and `migration_version: 1`. No Apple refresh grant,
raw subject or private mailbox is returned. The native client validates the same
UUID from the authenticated application profile before committing its session.

The server verifies Apple's RS256 signature against the fixed Apple JWKS,
issuer, exact native audience, expiry, fresh issue time and required nonce. It
atomically reserves code/nonce replay keys, exchanges the one-time code with
Apple, persists its encrypted refresh grant, and checks the exchanged ID token
has the identical subject and nonce. An unknown exchange outcome retains an
`uncertain` attempt. A fresh independently verified Apple login may continue
after the prior account lease ends, preserving the same UUID. The unresolved
attempt remains a deletion obligation: it is never expired, discarded, or
assumed revoked because another token was issued. A stale worker cannot publish
a session after losing its lease but can still durably capture a late grant.

Only the imported subject HMAC resolves ownership. Its format deliberately
matches the historical credential store:

```
subject_key = "apple-subject:" + hex(HMAC-SHA256(
  SPYCLASH_PSEUDONYM_KEY,
  "spyclash-apple-refresh-token-v1:subject:" + verified_apple_sub))
identity_key = hex(SHA256("https://appleid.apple.com\n" + subject_key))
```

An imported row retains its historical UUID and exact private Auth mailbox.
There is no email comparison with Apple claims, client supplied owner ID,
Base44 SSO request, custom JWT minting or direct write to managed Auth tables.
The server uses documented Auth admin `generateLink` and `verifyOtp` APIs, then
checks the returned UUID, live `/user` readback, database session and account
deletion gate. The resulting Auth AMR is the supported email/OTP mechanism;
trusted Apple provenance is held in the private account registry. This does
not manufacture a managed `provider=apple` identity. Future migration to native
`linkIdentity({provider:'apple',token,nonce})` is supported by current Supabase
SDKs but first requires an authenticated same-UUID session and enabled manual
linking; plain `signInWithIdToken` cannot preserve these imported synthetic-email
accounts by itself.

Configuration is server-owned and fails closed. Required: `APPLE_SESSION_ENABLED=true`,
`APPLE_SESSION_ENVIRONMENT=main`, exact current project Supabase URL/DB/Auth keys,
`APPLE_NATIVE_CLIENT_ID=com.spyclash.ios`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`,
`APPLE_PRIVATE_KEY_P8_B64`, historical `SPYCLASH_PSEUDONYM_KEY`, and a 32-byte
`APPLE_GRANT_ENCRYPTION_KEY` (or existing `PUSH_TOKEN_ENCRYPTION_KEY`). The grant
key accepts hex or base64url. No credential values belong in source or logs.
Unknown identities are denied unless **both** `APPLE_NEW_ACCOUNTS_ENABLED=true`
and `APPLE_MIGRATION_COVERAGE_VERIFIED=true` have been separately approved.
The only alternate target is the established `127.0.0.1:56321/56322` local test
stack with environment `local-test`.

Deletion calls `revokeAllAppleGrants` after placing the account in `deleting`
under its exclusive advisory lock. Every active grant is retained, encrypted
with its exact grant ID/UUID/client-ID binding; imported grants must be rewrapped
into this format. Revocation uses each grant's original client ID, and ciphertext
is erased only after Apple confirms revocation. An untracked or ambiguous
issuance blocks deletion completion. No runtime operation destroys a prior
grant just because a new authorization was received.

Run `deno check --config supabase/functions/apple-session/deno.json
supabase/functions/apple-session/index.ts` and `deno test --allow-env --config
supabase/functions/apple-session/deno.json tests/apple-session/`. Synthetic
tests exercise real JWT cryptography and mocked external services; they do not
establish production deployment, real Apple sign-in, or physical iPhone results.

Primary API references checked 2026-11-19:

- [Apple identity verification](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [Apple token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
- [Supabase generateLink](https://supabase.com/docs/reference/javascript/auth-admin-generatelink)
- [Supabase verifyOtp](https://supabase.com/docs/reference/javascript/auth-verifyotp)
- [Supabase identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking)
