# SpyClash 0000 — Game Center first-launch experiment

Prepared on 2026-10-25 from build 197 (`e5e33b1c`) in the separate
`davidganzha/game-center-000` branch. The working 197–198 checkout and production
backend are not the deployment targets of this experiment.

## Candidate identity

- App display name: **SpyClash 0000**; user-facing experiment label: **0.000 / 0000**.
- Apple version/build: **0.0.0 (2)**, a separate build sequence for a new bundle.
- Bundle: `com.spyclash.ios.gamecenter000`; scheme: `SpyClash-GameCenter-000`.
- Compile flags: `SPYCLASH_SUPABASE SPYCLASH_GAME_CENTER_EXPERIMENT`.
- Dedicated Supabase project: `spyclash-gamecenter000` / `ovowoixuyabccgkxcexp`.
- The bundle contains only a public client key. Backend configuration is pinned
  to that HTTPS origin; localhost is allowed for Debug QA only by the build guard.
- Original target build metadata advances 197 → 198 in this branch to satisfy
  repository versioning. The experimental target overrides it with its own sequence (now build 2).

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

- 35 experimental XCTest tests passed: native session ownership, refresh,
  profile identity, cancellation, GameKit callbacks, opt-out/retry, recovery links,
  exact backend allowlist and routing to account onboarding.
- 54 existing Supabase session and legacy-session-upgrade tests passed.
- 16 backend unit tests and 11 local Auth/Postgres integration checks passed.
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

The user approved creating the separate Apple app and internal TestFlight access
for David only. App Store Connect app **6826854338** (`SpyClash 0000`, SKU
`spyclash-gamecenter-000`, iOS, en-US) now exists. Bundle ID **C7V8SKWP23** and
App Store profile **87UJUKWU62** have Game Center enabled; the app version is
0.0.0 with manual release. No App Review or public release is requested.

The API key could read Apple records but returned 403 for identifier/profile
creation, so these approved operations were completed in Apple Developer UI.
Internal group **GC000 Internal** (`aa3ffecf-e9a0-4a6f-87ca-cae58f6e9d92`)
contains only David, with automatic build distribution disabled and no public
link. TestFlight upload has not yet occurred. The onboarding correction advances the
candidate from build 1 to build 2; delivery evidence will be recorded separately.

## Onboarding correction (build 2)

A temporary cloud QA account was removed during cleanup while the manual
Simulator still held its session. Its final onboarding save correctly received
401, but the app showed a generic retry toast indefinitely. The persistent manual
QA account is now explicitly excluded from automatic cleanup.

Experimental onboarding now returns to sign-in after a rejected session, with a
localized explanation and the chosen language retained. Transient server errors
remain retryable. Attempt ownership checks prevent an old response from signing
out a newer session or a replacement account. The isolated server wrappers now
preserve Auth outages as retryable 503 instead of incorrectly converting all
Auth errors to 401. Production endpoints and working 197–198 remain unchanged.

Verification: 35 experimental XCTest cases passed (including five new recovery
cases) on a separate clean Simulator. Sixteen backend unit tests and the exact
native v2 cloud payload save/readback passed. In the manual Simulator, a real
persistent cloud account completed language selection → explanation → Play →
Home successfully in build 2. Terminate/relaunch restored the same completed
account directly to Home. Cloud readback confirmed version 2, language `ru`,
completion timestamp and an active Auth session.

For real Simulator authentication, the runtime bundle was rebuilt with
`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` and passed the repository's
pre/post-install signature and Keychain identity gate. Unit-test artifacts built
without signing are not valid live-auth runtime evidence.
