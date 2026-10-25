# SpyClash 0000 — Game Center first-launch experiment

Prepared on 2026-10-25 from build 197 (`e5e33b1c`) in the separate
`davidganzha/game-center-000` branch. The working 197–198 checkout and production
backend are not the deployment targets of this experiment.

## Candidate identity

- App display name: **SpyClash 0000**; user-facing experiment label: **0.000 / 0000**.
- Apple version/build: **0.0.0 (1)**, a separate build sequence for a new bundle.
- Bundle: `com.spyclash.ios.gamecenter000`; scheme: `SpyClash-GameCenter-000`.
- Compile flags: `SPYCLASH_SUPABASE SPYCLASH_GAME_CENTER_EXPERIMENT`.
- Dedicated Supabase project: `spyclash-gamecenter000` / `ovowoixuyabccgkxcexp`.
- The bundle contains only a public client key. Backend configuration is pinned
  to that HTTPS origin; localhost is allowed for Debug QA only by the build guard.
- Original target build metadata advances 197 → 198 in this branch to satisfy
  repository versioning. The experimental target overrides it with its own build 1.

## Behavior

After restoring any saved account, a fresh launch asks Game Center for a verified
identity. The server validates Apple's signature, creates or finds the matching
experimental account, and issues a real Supabase session. The app verifies the
profile before committing it and routes a new account directly to the existing
onboarding. Returning accounts keep their saved onboarding state.

Declining Game Center, missing configuration, timeout or server failure opens the
existing email/password registration flow. The experiment routes that flow to its
own Supabase Auth, including email confirmation, recovery and refresh. Choosing
classic sign-in or logging out prevents automatic Game Center re-entry. An explicit
Game Center button permits a new attempt. Late callbacks cannot replace a newer
sign-in or password recovery request.

The new experimental account is separate from any working SpyClash account.
Automatic production account linking/migration, billing, push, Apple/Google OAuth
and Base44 integrations are outside this experiment.

## Verification

- 30 experimental XCTest tests passed: native session ownership, refresh,
  profile identity, cancellation, GameKit callbacks, opt-out/retry, recovery links,
  exact backend allowlist and routing to account onboarding.
- 54 existing Supabase session and legacy-session-upgrade tests passed.
- 11 backend unit tests and 11 local Auth/Postgres integration checks passed.
  Cryptographic integration fixtures are synthetic; the sessions and DB reads are real.
- Simulator app installed and launched on dedicated **SpyClash Game Center 0000**
  (`A6F0B98B-9024-46B0-9774-E8C53201C432`). Game Center unavailability opened
  classic registration. Real local registration reached account onboarding and
  survived app restart. A separate cloud test account also reached onboarding and
  restored after app restart.
- The current Apple `gc-prod-12.cer` certificate chain was checked. The deployed
  isolated endpoint rejects a forged proof with HTTP 401; this is not proof of a
  successful Apple player login.
- Generic-iOS Release compilation/archive is checked separately from signing.
  Unsigned archives and local logs are under `.local/gamecenter-signing-preflight/`.

## Remaining TestFlight boundary

Actual Game Center authentication, system greeting and first-launch timing still
need acceptance on an iPhone with a signed, Game Center-enabled application.

Read-only Apple preflight found no Bundle ID, App Store Connect app or provisioning
profile for the new bundle. David's existing distribution certificate is usable.
The concrete next operations are registering the new test identifier, enabling
Game Center, creating its distribution profile and separate App Store Connect app
(`SpyClash 0000`, SKU `spyclash-gamecenter-000`, iOS, en-US), then signing and
uploading version 0.0.0 (1) for internal testing. App Store Connect app creation
must use its website. No App Review or public App Store release is requested.

These Apple mutations and TestFlight delivery have **not** been performed.
Obtain the fresh exact-action confirmation required by `AGENTS.md` before them.
