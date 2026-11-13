# SpyClash 1.0.4 (238) — App Store Connect upload

On 13 November 2026 the user explicitly approved uploading the exact prepared
build238 in the current chat. Apple accepted the upload at 02:23:29 UTC.
The following readback confirmed processing completed successfully:

- App: `6793534085`; bundle: `com.spyclash.ios`.
- Version/build: **1.0.4 (238)**.
- Build/delivery ID: `0aa55760-da71-4622-a1b3-e3ecc9aa673f`.
- Processing: **VALID**; audience: **APP_STORE_ELIGIBLE**.
- Internal beta state: `READY_FOR_BETA_TESTING`.
- External beta state: `READY_FOR_BETA_SUBMISSION`.
- IPA bytes: `19085603`.
- IPA SHA-256: `aed443ff64d1580c1183c417a442498a7fa8fe77fac02b62a9f08cb59a4e50f4`.
- Reviewed source checkpoint: `0f78ae222264e08d5dd122f69bae12a773f3f627`.

The original signed IPA was uploaded without rebuilding or changing its bytes.
An independent preflight repeated its signed release gate and verified the
public configuration, effective production entitlements and disabled test flags.

This action did not submit the app for review, release it publicly, change
tester groups, deploy backend or website changes, or activate monthly/reward
configuration. Monthly App Store metadata, Unity setup and distribution-device
acceptance remain the separate gates in
[the release plan](APP-STORE-238-RELEASE-PLAN.md).

Evidence: [upload receipt](../QA/app-store-upload-238/upload-receipt.json),
[Apple readback](../QA/app-store-upload-238/apple-readback.json),
[upload log](../QA/app-store-upload-238/upload.log).

This is an administrative receipt for the existing238 artifact. No shipped
source or build settings changed; both project version values remain238.
