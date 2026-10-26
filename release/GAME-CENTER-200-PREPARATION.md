# SpyClash 1.0.3 (200): main Game Center integration

New players can accept Apple's Game Center sign-in and receive a persistent
SpyClash account. Account onboarding appears only after authenticated login and
only while that account has not completed it. A completed account goes directly
to the game even if its stored onboarding version is older or absent. Ordinary
Apple, Google and email registration remain available when Game Center is
cancelled, delayed, offline or unavailable.

This is prepared source and local verification, not a production deployment or
an uploaded TestFlight build. The separate `0000` app, server and persistent QA
account remain unchanged. The original main preparation checkout is untouched.

## Client and account behavior

- Startup restores a saved account first. Automatic GC runs only when no saved
  credential was present at launch; an expired credential cannot silently create
  an unrelated GC account. Existing accounts are never linked by nickname/email.
- GameKit proof is verified on the server before accepting the session. The
  native Supabase credential kind preserves refresh and ordinary revocation.
- Acceptance and user publication are synchronous; room restoration follows in
  an account-scoped task. Cancellation, logout, replacement login and recovery
  cannot let an old callback overwrite the current session or onboarding UI.
- Onboarding save handles an invalid session by returning to authentication;
  temporary failures remain retryable. It never reports an unsaved completion.
- Native GC deletion requires `native_account_deleted=true`. Existing full
  legacy deletion continues to require `original_account_deleted=true`, keeping
  the build-199 durable-request safeguard in its own prerequisite commit.

## All account features

Native GC accounts use server-owned membership, weekly StoreKit purchase and
restore, premium customization, full paid history and AI generation. Free
accounts have ten AI generations per UTC day and their newest five matches.
AI requests have durable results, quota reservations and fenced worker leases;
a lost acknowledgement does not charge a second logical generation.

Subscription verification pins the main bundle, product and Apple app ID.
Verified purchase ownership never changes on restore. Both Sandbox and
Production can be explicitly enabled for TestFlight/App Store. Canonical Apple
subscription status is checked before membership/premium consumption when the
last verification is older than 60 seconds, including expired subscriptions.
Refund/revocation therefore has a maximum 60-second cached authorization window.
Temporary verification failures return retryable errors and retain the saved
transaction. Ordinary gameplay and language changes do not depend on Apple.
Existing Base44 billing and its webhooks stay unchanged.

## Delivery target

- Main Apple app `6793534085`, bundle `com.spyclash.ios`, version `1.0.3 (200)`.
- First phone QA: `SpyClash-Supabase-Main-Candidate` / `SupabaseRelease`, the existing private
  `Supabase Main Internal QA` group (only David; automatic build inclusion off).
  Do not assign to the shared LIMITLESS group or the external group/public link.
- Main distribution profile prepared in project configuration:
  `SpyClash App Store Game Center 2026-10-26`. This profile does not exist yet and
  must be created only after approval, preserving Apple Sign-In and production
  push while adding Game Center. Widget profile remains unchanged.
- Public configuration also compiles, but its inherited full legacy account
  deletion flag requires the separately prepared build-199 production deletion
  protocol before any public submission. Candidate keeps that flag disabled;
  native GC full deletion is independently supported.

The current main Apple capability/profile audit found no Game Center entitlement.
No signed distributable build-200 IPA or Apple validation/upload is claimed yet.
Unsigned archives prove device compilation only and cannot be installed.

## Server package and exact prerequisites

Read-only production inspection on 2026-10-26 found `app-services` v10,
`full-game-core` v7 and `legacy-session` v3. GC identity storage and the full
legacy deletion-intent table are absent; existing legacy identity and Apple
entitlement tables are present.

After fresh explicit approval, the prepared main-server operation is:

1. Apply `20261013010810_main_account_deletion_intent.sql` (empty private journal,
   RLS/revoked public grants; this does not enable legacy deletion) and then
   `20261026172415_main_game_center_identity.sql` to `bbkfsgnordtdiblgdzkg`.
2. Deploy the reviewed `game-center-session`, `app-services`, `full-game-core`
   code and lockfiles as one coordinated package. Use the dedicated deployment
   snapshot, not a blind deploy from the source tree: it preserves the currently
   deployed engine, push, worker and Live Activity policy files. It pins full
   legacy deletion off in the app entry point while supporting native GC deletion.
3. Configure/enable main GC, native AI and native Apple verification only after
   the required server keys/roots are available. Exact variable names and gates
   are in [the backend package](../experiments/supabase-game-core/GAME-CENTER-MAIN.md).
4. Read back deployed code/schema/flags and conventional-account compatibility.
   Enable the main Apple capability/profile, sign/validate build 200 and deliver
   it only to the approved internal tester; then verify genuine GC onboarding,
   returning-account restoration, purchases and AI on the iPhone.

Server schema/function/secret changes, Apple capability/profile changes and
TestFlight delivery need a fresh confirmation in this chat. GitHub checkpoints
are source backups and do not authorize these operations. No App Review or
public App Store release is part of this step.

The source baseline contains previously prepared host-transfer and main-push
changes that are outside this rollout. The deployment package freezes their
live server versions and validates their SHA-256; the working branch keeps the
original main-source history. The signed client target is Main Candidate, not
a public App Store submission.

Server key readiness is still unverified: the connected Supabase API does not
expose secret metadata and the local CLI has no active login. The checked local
paths/process do not contain the needed OpenAI or App Store Server key material.
The working App Store Connect API key is not assumed to be an IAP verification
key. Do not enable purchases/AI until the proper keys/Apple roots are configured
and verified securely; never put their values in chat, Git or this document.

## Local evidence

- Signed Simulator staging: 144 passed, 0 failed/skipped, including 40 new GC,
  native-session/deletion, onboarding ownership and recovery cases, plus all
  existing session regressions (including build 199).
- Main onboarding policy: 12 passed, 0 failed/skipped.
- Backend: 31 genuine local Auth/Postgres integration checks, 15 GC security
  tests, 36 legacy regressions and 25 reused provider/quality/safety tests passed.
- Native billing: 11 database/verifier-boundary tests passed. Existing combined
  billing/push suite: 25 passed. These overlap some legacy checks above.
- Exact minimal server overlay: 31 Auth/Postgres + 11 native billing + 15 live
  engine/leaderboard checks passed. The two pending host-transfer cases are
  excluded; that feature is absent from this package.
- Public Simulator artifact passed the release-bundle gate.
- Release package fixtures: 70 passed, 0 failed, including missing GC flag and
  missing signed GC entitlement rejection.
- Public configuration: 3 passed, 0 failed/skipped, including the GC capability.
- Existing authentication: 53 passed, 0 failed/skipped (Apple ownership, normal
  flow, WebKit fixtures). The separate real-HTTPS-proxy case was intentionally
  excluded because it requires a temporary trust/TLS fixture; its code is unchanged.
- Total executed XCTest: 212 passed, 0 failed/skipped.
- Swift Simulator builds and Deno checks passed. Both Public and Main Candidate
  iphoneos archives built successfully and link GameKit.

Simulator installation uses the unchanged repository signature/Keychain gate.
Xcode's injected test frameworks omit sealed SDK Headers/Modules; local test
artifacts restore those exact SDK resources and are re-sealed before the gate.
Embedded unsigned test dSYMs are preserved outside the runnable app. These
artifact-only repairs do not change application source or weaken validation.

Synthetic Apple signatures, mocked provider responses and signed Simulator tests
do not prove real Game Center sign-in, paid AI service availability, StoreKit
purchase/refund on an iPhone, or production readiness. Those remain device and
server acceptance steps after authorization.
