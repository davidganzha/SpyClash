# AdMob readiness — build 219

Prepared from `d813561c398fbc62a18958331bca023cc1e303bd` (1.0.4 build 218) on 7 November 2026. No production deployment, AdMob setting change, App Store action or live credit grant is part of this checkpoint.

## Observed service state

- AdMob publisher: `pub-5081830513960558`.
- iOS app: `ca-app-pub-5081830513960558~9442838104`; App Store `6793534085`.
- At approximately 18:06 London, app verification succeeded. App readiness remained **Getting ready / Review in progress**, and account approval was still pending.
- Public `https://spyclash.com/app-ads.txt` returned one redirect to Base44 public storage followed by HTTP 200 and the expected Google publisher record.
- At approximately 18:40–18:47, rewarded unit `ca-app-pub-5081830513960558/6816674766` had reward **1 generation**, **No callback URL provided**, and Video / Ad pods / Interactive enabled.
- European regulations Messages displayed the create-message onboarding screen. Automatic/fallback message coverage was enabled in Settings. No consent message was created or published during this inspection.
- Base44 did not have `GenerationReward`, `generationRewardAction`, `SPYCLASH_REWARDED_GENERATION_ENABLED` or `ADMOB_REWARDED_AD_UNIT_ID` published/configured.
- Supabase project `bbkfsgnordtdiblgdzkg` had `app-services` v17 with JWT verification enabled. Its live bundle did not include rewarded generation routes; migration `20261105224817_rewarded_generation_credits` and the two reward configuration secret names were absent.

These observations are time-specific. App verification is not evidence of ad serving approval, deployed reward accounting or real Google-to-server delivery.

## Local preparation

The agreed product behavior remains three free generations per UTC day, one optional rewarded ad per additional generation, and unlimited verified LIMITLESS access. No between-round ads were introduced.

`release/AdMobOwnedSimulatorTest.xcconfig` is an explicit local opt-in for Debug or SupabaseDebug. It supplies the existing owned app/unit IDs. The runtime accepts it only on an iOS Simulator; physical Debug remains limited to the official Google sample pair. Release fails closed with this test override, and the release bundle gate independently rejects it. Normal project configurations do not include this file.

`isTestConfiguration` retains its original meaning: Google's exact sample pair. Owned-unit testing cannot enable the sample-only TrueView override or the isolated preview reward flow. Use the normal authenticated flow against a reviewed test backend for eventual end-to-end validation, not the UI preview flags.

Google documents that iOS Simulators are automatically test devices: <https://developers.google.com/admob/ios/test-ads>. No mediation adapter is configured in this checkpoint.

Live Base44 word normalization and the `whole-items-v2` cache version are preserved in the local reward candidate. This avoids reverting the live fix that keeps one provider item containing commas/semicolons as one game word.

The dedicated public callback validates the Google signature, then routes the signed server-issued token namespace (`UUID.native.64hex` or `UUID.legacy.64hex`) to the account's original ledger. Legacy forwarding preserves the raw signed query and rejects redirects, unexpected destinations and unsuccessful responses. Both ledgers still verify the exact issued claim and prevent duplicate credits. Native preparation normalizes uppercase UUID requests before issuing the token.

Frozen publication packages are stored under the local `admob-setup` evidence directory:

- Base44: `base44-readonly-20261107-1840/evidence/deployment-candidate` — 49 hashed files. Only the new entity and three specified functions are proposed.
- Supabase: `supabase-preparation-219` — 85 hashed candidate files, based on live app-services v17. Of 68 existing live source files, 61 remain byte-identical. Seven files receive reward integration changes; unrelated local feature changes are excluded.

Both manifests are retained here: [Base44 hashes](base44-candidate-sha256.json), [Supabase hashes](supabase-candidate-sha256.json). The publication scope and readback order are in [the approval plan](../../release/ADMOB-SERVER-PREPARATION-219.md).

## Activation boundaries

Do not use the old `app-services/rewarded-generation/ssv` URL as the AdMob callback while that function enforces JWTs. Google cannot provide a player's bearer token. The dedicated public callback prepared in this checkpoint is authenticated by Google's signed event; the existing app-services JWT setting must remain enabled.

Publish server resources with the feature switch disabled first, only after fresh explicit approval. Verify readback and handler rejection of unsigned requests before enabling a reviewed test path. Keep one canonical wallet for each account and confirm that both native and legacy callbacks route to it.

Before any ad-enabled public release, finish real signed callback testing, privacy-options lifecycle review, applicable consent configuration, the live website privacy-policy audit, App Store privacy disclosures, and current Google attribution setup. The current conservative age treatment must not be relaxed merely to obtain ads. This checkpoint does not claim those release prerequisites are complete.

## Validation

- Release artifact gate: **81 passed, 0 failed**; see [release-gate.txt](release-gate.txt).
- Standalone configuration XCTest: **9 passed, 0 failed**. Includes physical Debug rejection, Release rejection of the test override, publisher/ID mismatch and server-unit replacement rejection.
- iOS Simulator XCTest: **12 passed, 0 failed** (9 configuration, 3 transition/cancellation tests) in the signed Debug app target.
- Explicit owned-unit Simulator build: **passed**, code signature verified and built Info.plist values read back; see [owned-simulator-build.json](owned-simulator-build.json). This is compile/artifact verification, not a live advertisement or Google callback test.
- Xcode evidence: `~/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-11-07T18-46-14-722Z_pid66901_00223671.xcresult`.
- Base44 targeted coverage: **56 tests and 15 substeps passed**. Includes the whole-item punctuation regression and preservation of live CASADA behavior with rewards disabled. The exact publication package additionally passed all three entrypoint type checks and its **11 handler integration tests**.
- Exact minimal Supabase candidate: both entrypoint type checks passed, **8 signed gateway tests** and **18 isolated PostgreSQL checks** passed. These cover native delivery through the public gateway, duplicate grants, refunds, account separation, LIMITLESS, UTC reset, delayed outcomes and deletion.
- Root readback verified **49 Base44 + 85 Supabase candidate file hashes** and synchronized build number 219. Independent source review found no blocking issue in the gateway or Simulator/Release gates.

All server tests use local fixtures; no live Google callback or production reward grant is claimed.
