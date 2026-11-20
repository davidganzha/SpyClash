# SpyClash 1.0.4 (254) — TestFlight acceptance candidate

On 20 November 2026 the user approved the exact prepared IPA for App Store
Connect app `6793534085` (`com.spyclash.ios`), its assignment to the existing
internal QA group, and the prepared Russian test notes. The upload completed
once at 22:19:20 UTC with no errors. Apple subsequently confirmed:

- Build/delivery ID: `ee95e3ea-5fc0-4d7b-a121-8eccc488ce65`.
- Version/build: **1.0.4 (254)**.
- Processing: **VALID**; audience: **APP_STORE_ELIGIBLE**.
- Internal beta: **IN_BETA_TESTING**.
- Group: **LIMITLESS Internal QA**,
  `47a13858-b43b-44a1-bf3e-285722cec320`; the same two testers remain members.
- Russian What to Test notes were saved and read back exactly.
- IPA: 19,634,999 bytes; SHA-256
  `ef0e69546e6cb34cdcbd80e679cb398156bebb713eced382feb57acbe8ff9d87`.
- Shipped source: `2a06e9cc409d984cca31dc565e53ee381081735e`;
  [complete green CI](https://github.com/davidganzha/SpyClash/actions/runs/44815132885).

## Artifact and signing verification

The optimized `SupabasePublicRelease` archive was built from an immutable
copy of the 2,009 tracked source files. Their hashes matched the source
checkpoint and working tree. The public Supabase configuration and native
Apple sign-in are included, with production ad settings and no local StoreKit
configuration or internal-only TestFlight restriction.

Export used the existing Xcode Apple-ID cloud signing route and existing
Apple Distribution certificate SHA-1
`5B10F9DA0BA68FF878BDB8FEC48184416F1FF887`, team `3Z64QKNL54`.
The final app, widget and all three embedded SDK framework bundles were checked
individually for valid signatures and the exact certificate. App and widget
UUIDs match the archive and dSYMs. Effective app entitlements include native
Apple sign-in, Game Center, production push and disabled debugging. Their
application identifiers and keychain groups match development build 247.

The first validation caught invalid designated requirements on the SDK resource
frameworks: export had retained the temporary `arm64-apple` identifier in their
requirements. The archive's framework bundles were signed temporarily with
their actual bundle identifiers before repeating the cloud export. Individual
designated-requirement checks and Apple's second validation then passed. Only
the corrected IPA above was uploaded. App implementation and SDK versions did
not change during this signing repair.

Apple validation and upload reported warning 90725: iOS 27 SDK will be required
starting April 2027. This iOS 26.5 SDK candidate was accepted without errors.

## Physical acceptance

Ganzha was connected and its existing development installation was independently
identified as 1.0.4 (247). The user was asked to update through TestFlight to
254 and report whether the existing account opened. Installation and acceptance
results must be recorded separately; upload success proves neither.

Remaining checks on the actual TestFlight installation:

1. Existing Apple login and session restoration after fully closing/reopening.
2. Monthly LIMITLESS sandbox purchase and entitlement delivery.
3. Purchase restoration and entitlement persistence after relaunch.
4. Legacy weekly restoration where the testing Apple Account has such history.

TestFlight purchases use Apple's sandbox without real charges; see
[Apple's TestFlight purchase testing guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight).
A genuinely new Apple ID registration remains a separate check from signing
back in with an existing Apple Account.

Evidence: [sanitized Apple readback](../QA/testflight-254/upload-readback.json)
and [exact test notes](../QA/testflight-254/what-to-test-ru.txt). Raw operational
logs and the signed IPA remain private under `.local/testflight-254/` and the
staging paths recorded there.

No App Review submission, external beta submission, public release, App Store
draft build attachment or backend change was made. The 1.0.4 App Store draft
still references build 238. This administrative receipt records the existing
254 artifact; shipped source and both project build values remain 254.
