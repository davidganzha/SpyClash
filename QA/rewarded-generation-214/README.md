# Rewarded generation — build 214

Prepared on 2026-11-05 from build 213 (`440a5438`). Marketing version remains 1.0.3. This checkpoint does not deploy or activate any production environment.

## Player behavior

- Three free AI generations per UTC day, shared across generation entry points and devices for the same account. The reset time is displayed in the device's local time zone.
- After those are used, a voluntary rewarded ad earns one additional generation. Previously earned credits are used before another ad is offered and do not expire at midnight.
- Actual verified LIMITLESS membership is unlimited. Other existing CASADA benefits are unchanged.
- Saved packs, manual word entry, and rounds do not require an ad. No interstitial or round-boundary advertising was added.
- Closing an ad before its earned event or receiving no ad gives no credit. An earned event is journaled immediately; the real balance changes only after a verified server callback. Pending confirmation recovers automatically for the signed-in account, including after relaunch.
- Confirmed generation failures restore the reservation once. An ambiguous provider result remains held for same-request reconciliation and cannot repeat paid provider work.

## Current test configuration

Google Mobile Ads 13.12.0 and User Messaging Platform 3.1.0 are pinned. Debug and SupabaseDebug use only Google's official test application and rewarded unit. Release configurations have advertising disabled and empty IDs. The SDK starts only after an explicit request to watch; advertising is non-personalized, first-party publisher ID and coarse-location collection are disabled, and conservative age-restricted treatment is applied.

The Google sample unit cannot award server credits. Until an owned AdMob unit exists, UI testing uses an isolated DEBUG preview; server tests use signed fixtures against a local ledger. The preview never sends a real generation request, persists a bonus, or changes a real account.

Launch a signed Debug build with:

```text
--spyclash-ui-preview --spyclash-preview-direct=generation-rewards --spyclash-preview-generations
```

The preview's test-generation button consumes its three local free uses. `--spyclash-preview-generations-exhausted` opens the exhausted state; `--spyclash-preview-generations-unlimited` opens the unlimited state. These flags are DEBUG-only.

## Backend wiring

Both native Supabase accounts and legacy Base44 accounts have server-owned ledgers. Supabase routes legacy accounts to their existing Base44 wallet after verifying account ownership; it does not create a second wallet.

- Feature switch: `SPYCLASH_REWARDED_GENERATION_ENABLED=true`. Default: disabled, preserving existing generation access.
- Owned rewarded unit: `ADMOB_REWARDED_AD_UNIT_ID`. Public sample IDs are rejected for real credits.
- Reward: exactly `1 generation`.
- Supabase callback: `GET /functions/v1/app-services/rewarded-generation/ssv`.
- Base44 callback: public GET URL of `generationRewardAction`.
- Authenticated actions: `status`, `prepare` with a UUID request ID, and `claim_status` with an attempt ID. Pass the returned opaque user ID and custom data unchanged to the SDK.
- Native migration: `experiments/supabase-game-core/supabase/migrations/20261105224817_rewarded_generation_credits.sql`.
- Base44 resource and function: `GenerationReward`, `generationRewardAction`. Details and offline test commands: [function README](../../base44/functions/generationRewardAction/README.md).

The same Google ECDSA verifier is used by both backends. Credits are bound to account, attempt, unit and transaction; replayed callbacks cannot grant twice. Account deletion removes the ledger and prevents late callbacks from recreating it.

## Verification

- Signed iOS Simulator Debug build: passed. Bundle signature, installed build 214 and Keychain identity verified by the repository installation gate.
- SupabaseDebug main-candidate build: passed.
- SupabasePublicRelease Simulator build: passed, with ads disabled by default.
- XCTest: **77 passed**, comprising 8 reward-store, 3 ad-configuration and 66 membership tests. Coverage includes incomplete/no-fill ads, client callback versus server confirmation, relaunch recovery, delayed callbacks across account changes, and SSV confirmation before ad dismissal.
- Base44: **83 passed**, comprising 57 unit, 11 real-handler local integration, and 15 schema/routing/deletion checks. Includes quota denial followed by earning a credit and successfully retrying the same request ID.
- Supabase: isolated local PostgreSQL and cryptographic SSV tests cover three free generations, exactly-once grants/spending/refunds, concurrency, account separation, midnight rollover, LIMITLESS, legacy routing, deletion and late signed relay recovery. The final test count is recorded in `backend-verification.txt`.
- Deno type checks, byte-identical SSV verifier comparison, and Git whitespace checks: passed.
- Runtime preview: verified 3-to-0 free counter and voluntary ad button. Google's real test creative loaded and displayed its reward-earned end card. Screenshots: [three free](three-free.jpg), [exhausted](exhausted.jpg), [Google test ad](google-test-ad.png).

The automated UI interface did not expose the test creative's close control; the fallback coordinate interface returned `noWindowsAvailable`. Ad dismissal-to-balance behavior is covered by the reward-store tests, not claimed as a completed visual end-to-end test. Actual Google-to-server SSV delivery, physical-device behavior and TestFlight are not verified by this checkpoint.

## Later activation

Create the AdMob app and owned rewarded unit, configure the applicable callback and reward, and validate real SSV delivery in an approved non-production environment. Production activation additionally needs the matching build-time app/unit IDs and explicit ad enablement, the server switch and migration/resources, and an updated App Store privacy declaration matching the SDK. Keep the conservative age treatment unless a reviewed age/consent flow replaces it. Review current Google SDK setup requirements, including SKAdNetwork IDs, before release.

Each production deployment/configuration change and any App Store or TestFlight submission requires fresh explicit approval in this chat immediately before that action under the project AGENTS.md rules. None was performed here.
