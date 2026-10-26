# Main SpyClash Game Center backend preparation

This package is local preparation for `com.spyclash.ios` on the existing main
Supabase project `bbkfsgnordtdiblgdzkg`. No production migration, function deploy,
secret update, Apple provisioning, or TestFlight upload was performed here.
The separate `game-center-000` project and its persistent QA account are untouched.

## Identity and account lifecycle

`POST /functions/v1/game-center-session` accepts only:

```json
{
  "team_player_id": "opaque Apple team player identity",
  "bundle_id": "com.spyclash.ios",
  "public_key_url": "https://static.gc.apple.com/public-key/gc-prod-12.cer",
  "signature": "base64",
  "salt": "base64",
  "timestamp": 0,
  "display_name": "Optional cosmetic nickname"
}
```

The example timestamp/signature are placeholders, not valid authentication.
The endpoint verifies Apple's certificate chain and RSA/SHA256 signature over
team player ID + bundle + UInt64 big-endian milliseconds + salt. It rejects stale
proofs, future timestamps, replay, noncanonical certificate URLs, redirects,
untrusted certificates, and the `0000` bundle. Certificate trust uses the current
DigiCert Trusted Root G4/code-signing intermediate. Certificate rotation fails
closed; OCSP/CRL fetching is not implemented.

Only the digest of the signed identity selects `game_center_private.accounts`.
Nickname, contact email, client provider flags, and editable Auth user metadata
never select or link an account. A new identity receives a reserved random UUID,
an internal random email, server-owned Auth metadata, and the ordinary profile.
Server-generated magic-link verification returns a standard revocable Supabase
session without sending email. Refresh works through Supabase Auth. UUID and
server metadata readbacks plus an existing `auth.sessions` row are required.

Success returns `provider: game_center`, `access_token`, `refresh_token`,
`token_type`, `expires_in`, `expires_at`, and `user.id`. Profile/current retains
the existing public actor key `UUID@example.test`. A new profile has
`onboarding_completed: false`; repeat login never resets a completed profile.

Full native account deletion is `profile/delete` with `deletion_scope: account`
and an immutable request UUID. It needs no Base44 credential and returns
`native_account_deleted: true`, never a false `original_account_deleted` claim.
The private GC mapping and absence of legacy ownership/deletion intents are
rechecked under the existing exclusive account lock. Native deletion scrubs game
content and generation results, tombstones the GC identity, and reuses durable
Auth cleanup. Existing Base44 deletion proof/recovery rules remain unchanged.
Deleted GC identities do not silently recreate accounts.

## AI and premium behavior

Native GC `legacy/status` returns `requires_legacy_session: false` and an explicit
generator capability. Native generation uses the existing direct OpenAI provider,
prompt, self-audit, theme-quality guard, exclusions, and content filtering copied
verbatim from `base44/functions/generateWordPack` into `app-services/word-generation`.
Legacy accounts continue to use their existing Base44 provider.

`game_center_private.generation_requests` durably owns each request UUID, result,
quota reservation, and renewable worker lease. Free native accounts receive ten
generations per UTC day. Only a valid server entitlement/grant removes that limit.
Reservations count toward the limit; explicit provider failure releases the
charge. A lost result acknowledgement replays the saved result without another
provider call or charge. Expired lease recovery fences late workers. A process
crash after a provider accepted work but before the result was saved can cause
another provider call on recovery; provider billing is not claimed exactly-once.
Account deletion prevents late results from recreating content.

Native free history is restricted to the newest five stored matches before
applying pagination, including when a former paid account reuses an old cursor.
Server entitlement/grant unlocks full history. Existing legacy history behavior
is preserved. Apple's owned subscription status is refreshed before premium
consumption when its last verification is older than 60 seconds. Verification
failure cannot grant paid access. Ordinary gameplay does not depend on that call.

## Deployment prerequisites — require a separate approved production action

1. Recheck the target's actual schema and migration history. Root's read-only
   inspection on 2026-10-26 found `app_private.main_account_deletions` absent in
   the main project despite the local migration file being present. The exact
   required additive order is:
   - `supabase/migrations/20261013010810_main_account_deletion_intent.sql`
   - `supabase/migrations/20261026172415_main_game_center_identity.sql`
   Do not replay unrelated baseline migrations. The GC migration fails before
   creating its tables if profiles, legacy ownership, or the deletion-intent
   prerequisite are missing. All new tables are private, RLS enabled, and have
   no public/anon/authenticated grants or callable public RPCs. Creating the
   empty deletion-intent table does not enable legacy account deletion or make
   a Base44 request; its separate rollout/recovery prerequisites remain required.
2. Deploy the reviewed `game-center-session`, `app-services`, and `full-game-core`
   artifacts together with their pinned imports/lockfiles. The endpoint uses
   `verify_jwt = false` because its initial credential is Apple's signed proof.
3. Server Auth/DB configuration must match the pinned main project. The main
   endpoint stays disabled unless `GAME_CENTER_ENABLED=true` and
   `GAME_CENTER_ENVIRONMENT=main`; optional `GAME_CENTER_PROJECT_REF` must equal
   the pinned project. Production DB connections use TLS and its existing pooler.
4. Native AI additionally requires `APP_NATIVE_GAME_CENTER_AI_ENABLED=true` and
   server-only `OPENAI_API_KEY`. `SPYCLASH_OPENAI_MODEL` is optional; otherwise the
   existing provider's pinned model remains in use. No key was copied or configured.
5. Native Apple billing requires the separate reviewed main billing configuration:
   `APP_IAP_ENABLED=true`, `APP_NATIVE_GAME_CENTER_IAP_ENABLED=true`,
   `APP_IAP_BUNDLE_ID=com.spyclash.ios`, `APP_IAP_APPLE_ID=6793534085`, the explicit
   approved environment, server verification keys/roots, and purchase rollout
   switches. Existing Base44 billing configuration and webhooks remain intact.
6. Verify a genuine signed Apple Game Center proof and real StoreKit lifecycle
   on the provisioned main app before declaring device or production acceptance.

Local mode is separately restricted to Auth `127.0.0.1:56321`, Postgres
`127.0.0.1:56322`, and `GAME_CENTER_ENVIRONMENT=local-test`. Test certificate roots
are injected only inside test code, never selected through HTTP/environment.

## Local verification (2026-10-26)

- `npm run game-center:test`: 15 signature, URL, freshness, configuration, and
  Auth error-boundary tests passed.
- `npm run game-center:integration`: 31 checks passed against genuine local
  Supabase Auth/Postgres, including identity races, lost create ACK, replay,
  conflicting identity metadata, refresh, onboarding persistence, deletion proof,
  late candidate revocation, generation quota/lease/idempotency, and history gating.
- `node scripts/game-center-local.mjs legacy-regression`: 36 existing legacy
  billing, push, session, and full account deletion tests passed.
- The 25 existing direct-provider, word-quality, and content-safety tests passed;
  the four copied provider/helper files were checked byte-for-byte.
- Deno checks passed for app-services, legacy-session, full-game-core, the new
  Game Center entry point, and its integration tests. Local security advisors
  reported no warnings or errors.

The local runner reads credentials in memory, refuses cloud-linked directories,
never resets the existing stack, and cleans only UUIDs created by its own tests.
Apple identity proofs and AI provider responses in tests are synthetic fixtures;
no genuine Apple sign-in, paid AI request, App Store purchase, or production
operation is claimed by these results.

References: [Apple identity verification](https://developer.apple.com/documentation/gamekit/gklocalplayer/fetchitems(foridentityverificationsignature:)),
[Apple certificate change](https://developer.apple.com/news/?id=stttq465),
[Supabase generateLink](https://supabase.com/docs/reference/javascript/auth-admin-generatelink),
[Supabase OTP verification](https://supabase.com/docs/guides/auth/auth-email-passwordless).

## Minimal deployment artifact

Use `scripts/package-main-game-center.py --test` from the repository root after
saving the reviewed read-only app-services v10/full-game-core v7 exports under
`.local/gamecenter-main200/deployed-source`. The script validates the complete
export fingerprints and four pinned live-file SHA-256 values, then writes the
manifest, exact live/planned diff and deterministic archive under
`.local/gamecenter-main200/server-source` and its parent directory.

This deployment overlay preserves the current engine/push/worker/Live Activity
policy, so pending host-transfer and main-push changes in the source baseline
are not deployed incidentally. Only its generated app entry point pins
`APP_MAIN_ACCOUNT_DELETION_ENABLED=false`; native GC deletion remains enabled by
verified identity. Never deploy the working directory instead of the approved
manifest. Re-read the live versions before deployment; stop if they changed.

The exact overlay passed 31 local Auth/Postgres, 11 native billing and 15 existing
engine/leaderboard checks. The two pending host-transfer tests are excluded
because that feature is deliberately absent from the frozen live engine.
