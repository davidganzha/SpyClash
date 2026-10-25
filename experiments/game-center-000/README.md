# SpyClash 0.000 — isolated Game Center backend

This package adds genuine Game Center verification and native Supabase sessions for the experimental bundle `com.spyclash.ios.gamecenter000`. The cloud artifact is pinned to the separate David Ganzha project `spyclash-gamecenter000` (`ovowoixuyabccgkxcexp`, eu-west-1). Working builds 197–198 and their backend are not modified. A Game Center identity creates a new experimental profile; it never merges into a production account by nickname or email.

## What is implemented

- The iOS app sends a fresh `fetchItems(forIdentityVerificationSignature:)` proof to `POST /functions/v1/game-center-session`.
- The endpoint checks the fixed experimental bundle, bounded opaque `teamPlayerID`, timestamp, current Apple certificate and RSA-SHA256 signature. Only canonical HTTPS `static.gc.apple.com/public-key/gc-prod-N.cer` / `gc-sb-N.cer` URLs are accepted; redirects are disabled.
- The certificate chain is verified to DigiCert Trusted Root G4 through its Code Signing RSA4096 SHA384 2021 CA1 intermediate. Apple subject, leaf code-signing EKU, RSA strength and validity dates are checked. The current leaf is always fetched from GameKit's URL, with bounded HTTP caching; no leaf URL or leaf certificate is pinned.
- The database atomically rejects reused proofs and reserves one random Auth UUID per verified identity. A renewable lease serializes first registration. Nicknames are unsigned cosmetic text and never a lookup key.
- Auth admin `createUser`, `generateLink`, and `verifyOtp` issue a normal Supabase session without delivering email. The server verifies the resulting bearer by Auth readback, checks `auth.sessions`, and creates the normal SpyClash profile with `onboarding_completed=false`.
- Native Supabase refresh works without Base44 credentials. Deleted profiles and missing previously issued Auth identities fail closed.
- Private identity and replay tables have RLS and no `anon`/`authenticated` grants. No service-role key is exposed to the app.

Request JSON:

```json
{
  "team_player_id": "<GKLocalPlayer.teamPlayerID>",
  "bundle_id": "com.spyclash.ios.gamecenter000",
  "public_key_url": "<current GameKit certificate URL>",
  "signature": "<standard base64>",
  "salt": "<standard base64>",
  "timestamp": 1792936800000,
  "display_name": "<optional unsigned nickname>"
}
```

Success returns `provider: "game_center"`, `access_token`, `refresh_token`, `token_type`, `expires_in`, `expires_at` and `user.id`. The client must fetch and verify the account profile before accepting the session. HTTP errors contain `code`, `message` and `retryable`; the client can then show classical registration. Proofs may be at most five minutes old, with thirty seconds of future-clock allowance. A retry must obtain a new GameKit proof.

## Local verification

From this directory:

```sh
npm ci
npm test
npm run test:local
npm run serve:local
```

The local runner discovers the existing dedicated `spyclash-game-core-test` containers through the local Colima Docker socket, requires API port 56321 and database port 56322, and applies only the new `gc000_private` schema. It does not reset the stack, migrate existing data, or contact a cloud project. Test accounts and profiles are cleaned using their exact generated UUIDs.

The loopback router listens on `http://127.0.0.1:56330` and supports:

- `/functions/v1/game-center-session`
- `/functions/v1/app-services`
- `/functions/v1/full-game-core`
- The native signup/login/refresh/OTP/recovery/logout paths under `/auth/v1/`.

Run `node scripts/local.mjs client-config` to print the loopback URL and public anon key. Admin keys and DB credentials stay in the child process environment. The router uses the production verifier; it has no synthetic-proof bypass. Fixtures can only be injected by tests.

`test:local` uses generated test certificates and real local Auth/Postgres. It proves provisioning, refresh, account restoration, race/replay handling and profile onboarding readback. It does **not** prove Apple Game Center login on an iPhone.

## Prepare an isolated cloud package

```sh
npm run prepare:package
```

This writes `.local/isolated-package/` containing the existing ordered SpyClash schema migrations, the new Game Center migration generated through Supabase CLI, and three self-contained Edge Functions. It copies the established app-services and full-game-core implementations and replaces only their environment bootstrap in the generated package. Original backend files remain unchanged. Preparation does not link, create, deploy, migrate, reset or publish anything remotely.

Use a separate nonproduction Supabase project or development branch **without production user data**. Review whether it already has the baseline migrations before applying the ordered files; do not reset an existing branch or import production users. The cloud entry points compile in the following non-secret experiment identity. No custom secret setter is required; conflicting environment overrides are rejected:

```text
GAME_CENTER_ENVIRONMENT=experimental-000
GAME_CENTER_PROJECT_REF=ovowoixuyabccgkxcexp
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_DB_URL` are supplied by Supabase and must all belong to that same pinned isolated environment. The guard permanently rejects the live `bbkfsgnordtdiblgdzkg` project. DB connections use TLS outside loopback; either the exact direct DB hostname or a Supabase pooler with username `postgres.<isolated-ref>` is accepted. Never copy live keys or change the denial to work around configuration failures.

The three generated endpoints perform their own verification, so `verify_jwt=false` is set in the generated function configuration. Native email/password/OTP use the isolated project's Auth settings. Configure the project's signup confirmation and delivery policy deliberately for the test; local automatic confirmation is not a recommendation for a public deployment.

Billing, production push and Base44 bridges are disabled by the generated app-services bootstrap. Full production account migration/linking is outside this experiment. The generated account-deletion worker uses the same strict isolated-environment guard; no production deletion bridge is enabled. Profile tombstones deny deleted-account access while Auth cleanup completes.

For an iPhone/TestFlight test, configure the new bundle's Game Center capability and signing, enable Game Center for that separate app, and embed only the isolated HTTPS URL and public client key. A real device must verify the first-launch flow and repeat-login account identity; local proof fixtures cannot replace that acceptance step.

## Trust sources and validation boundary

- Apple server identity verification: https://developer.apple.com/documentation/gamekit/gklocalplayer/fetchitems(foridentityverificationsignature:)
- Apple certificate issuer change: https://developer.apple.com/news/?id=stttq465
- Trusted root: https://cacerts.digicert.com/DigiCertTrustedRootG4.crt
- Intermediate: https://cacerts.digicert.com/DigiCertTrustedG4CodeSigningRSA4096SHA3842021CA1.crt
- Supabase Admin link generation: https://supabase.com/docs/reference/javascript/auth-admin-generatelink
- Supabase token verification: https://supabase.com/docs/reference/javascript/auth-verifyotp

The bundled public root SHA-256 is `552F7BDCF1A7AF9E6CE672017F4F12ABF77240C78E761AC203D1D9D20AC89988`. Live `gc-prod-12.cer` was fetched and its chain validated on 2026-10-25 (valid through 2027-05-27). A future intermediate/root rotation fails closed until reviewed trust material is updated. This is certificate-chain and proof verification, not an OCSP/CRL revocation service.


## Cloud deployment and readback — 2026-10-25

Only the newly created test project `ovowoixuyabccgkxcexp` was bootstrapped. It was confirmed empty before the `game_center_000_isolated_bootstrap` migration. No production project was modified.

| Endpoint | Active version | Downloaded source matches prepared artifact |
| --- | --- | --- |
| `game-center-session` | 4 | 15/15 files |
| `app-services` | 2 | 60/60 files |
| `full-game-core` | 2 | 39/39 files |

Deployment bundle SHA-256 values:

- Game Center: `9a58a4e43cfef7bbd395c3c4eee718b88a46f6017fd244f81579da3bbddae04f`
- App services: `2e70b776b3da4fc8371156d08e4ac7206c3bc11b51772e3986130585b9900738`
- Game core: `f9c8933c5f072ab9aaadc2e34ee276aad593171e6de67743bb01c31194391206`

Verified:

- 11 unit/security checks and 11 local real Auth/Postgres integration checks pass.
- All three generated Edge entry points pass `deno check`.
- A correctly shaped forged Game Center proof using the current Apple certificate returns HTTP 401. Version 4 logs contain a clean boot and no certificate-stage failure. This exercised certificate retrieval/chain validation and rejected the fake signature without creating a user or consuming a proof.
- Authless app-services and game-core requests return 401.
- A separately seeded, confirmed synthetic email identity completed real cloud password login, initial profile read, onboarding save/readback, token refresh and logout.
- The experimental iOS app reached the real cloud onboarding language screen with a separate synthetic fixture, and remained in onboarding after stop/relaunch and cloud session restoration (verified by the parent task).
- Supabase security advisor reported zero warning/error findings; its 38 informational findings describe private server-only tables with RLS and no client policies.
- Both cloud fixtures were deleted by exact UUID after verification. Final readback: zero Auth users, sessions, profiles, Game Center accounts and accepted Game Center proofs. Ignored local credential files were removed.

The hosted signup endpoint rejects reserved `@example.com` addresses. The cloud password/onboarding test therefore used an explicitly synthetic SQL-seeded fixture; it is **not** proof of email delivery or public signup confirmation. Local public signup was tested separately by the iOS task. No fake-auth endpoint or synthetic Game Center trust material is deployed.

A live Apple Game Center assertion and its first-login/return-login behavior still require the separately signed experimental app on an Apple device. No TestFlight upload or production release was performed by this backend task.
