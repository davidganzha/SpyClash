# SpyClash 1.0.4 (232) — TestFlight delivery

Status: **Apple processing completed; available to LIMITLESS Internal QA**. Availability was verified at **22:40:47 UTC on 11 November 2026**. The user explicitly approved uploading build 232 in this chat. No App Review submission or public App Store release is included.

Build 232 delivers the generated-name punctuation fix and retains build 231's generation-request recovery changes. It uses the same public release configuration, dependencies, advertising settings, signing profiles and privacy resources as build 230.

## Exact artifacts

- App: `6793534085`; bundle: `com.spyclash.ios`.
- Source commit: `8c107d367202ea1f7cceb4588a82c3505336debe`; [frozen iOS source hashes](ios-source-manifest.json).
- Scheme/configuration: `SpyClash-Supabase-Public` / `SupabasePublicRelease`.
- Signed archive: `/tmp/SpyClash-AppStore-232/SpyClash-1.0.4-232.xcarchive`.
- Export directory: `/tmp/SpyClash-AppStore-232/export` using `release/ExportOptions-AppStore.plist`.
- Uploaded IPA: `/Users/davidganzha/Documents/SpyClash/output/TestFlight-232-20261111/SpyClash-1.0.4-232.ipa`.
- IPA size: **18,982,691 bytes**; SHA-256: `f6806447a55d0b027e4fe4cf153b3945985259a76fd6cb6dcb69eed921870f0e`.
- Artifact receipt: `/Users/davidganzha/Documents/SpyClash/output/TestFlight-232-20261111/artifact.json`.

## Release validation

Archive and export succeeded with normal release settings. The [signed archive gate](archive-gate.log) and [exported IPA gate](ipa-gate.log) both passed for **1.0.4 (232)**, including the public Supabase package, distribution signatures/entitlements, embedded Live Activity extension, privacy manifest, StoreKit/Limitless content and production Unity configuration. Apple package validation reported **no errors**: [receipt](apple-validation.json), [log](apple-validation.log).

The earlier [word-pack verification](../word-pack-names-232/verification.json) recorded **218 passing tests**: 18 iOS Simulator tests, 149 Base44 tests, 18 native PostgreSQL integration checks and 33 rewarded-generation checks, plus 29 handler fixture steps. These are prior code/regression checks, separate from this release archive/export validation. They do not establish physical-device acceptance, paid live generation quality, real ad rewards or purchases.

## Upload and processing

Apple accepted the exact IPA at **22:28:45 UTC on 11 November 2026** with no upload errors. Delivery UUID: `a735064c-190e-4d17-8513-450d7c7c53d7`. See [upload receipt](testflight-upload.json) and [upload log](testflight-upload.log).

The App Store Connect `buildUploads` resource completed processing with no errors or warnings. Its transfer timestamp is 22:28:44 UTC; the build record reports 22:38:39 UTC. Build ID: `a735064c-190e-4d17-8513-450d7c7c53d7`. See the [processing receipt](apple-processing-final.json).

The existing **LIMITLESS Internal QA** group (`47a13858-b43b-44a1-bf3e-285722cec320`) was verified as internal and assigned this build; Apple returned **HTTP 204**. Read-back confirms **processingState: VALID**, **internalBuildState: IN_BETA_TESTING**, the expected group relationship and **usesNonExemptEncryption: false**. See the [assignment receipt](group-assignment.json), [final availability receipt](testflight-final-state.json), and [artifact summary](artifact.json). No external tester group or public beta review is part of this delivery.

[Open build 232 in App Store Connect](https://appstoreconnect.apple.com/apps/6793534085/testflight/ios/a735064c-190e-4d17-8513-450d7c7c53d7).

The separately approved server rollout is recorded in [word-pack deployment evidence](../word-pack-names-232/deployment.json). This TestFlight upload does not perform another backend deployment or change server flags.
