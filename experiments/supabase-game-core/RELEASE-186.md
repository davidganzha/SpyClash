# SpyClash 1.0.3 (186): internal TestFlight delivery

Delivered on 18 October 2026 after explicit approval in the current chat to sign and upload build 186 only for David and Dima. App Store Connect verified `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, and external testing `NOT_APPLICABLE` at **22:23:28 UTC / 23:23:28 London**.

## Delivered change

Apple session completion remains invisible after the native Apple authorization sheet. Build 186 cancels an owned token-candidate navigation before rendering and requires the original native Apple binding ticket and verified account identity before accepting the session. No visible browser fallback is added. See [APPLE-SIGN-IN-186.md](APPLE-SIGN-IN-186.md) for the reproduced build-185 rejection, focused tests and remaining physical-device uncertainty.

The exact source is `3fdd43eee82e8bfedcd704faf5529b2b0cb0dfc3` on `davidganzha/supabase-game-core`. Main app and widget are both 1.0.3 (186). A frozen copy of all 1,313 tracked files was used: 1,311 were byte-identical, with only six existing signing settings changed in the two project files. Source verification passed 11/11 before and after compilation, signed archive verification passed 17/17, and independent exported IPA verification passed 19/19. Preserved copies match the original artifacts byte for byte.

- App: `com.spyclash.ios`; App Store Connect app `6793534085`.
- Build ID: `76084d26-e12c-432e-a47b-3a2e9c225833`.
- IPA SHA-256: `68cc8e5d7c506a950ce62da96f269419447d09c340cb7b56e043ff22d159a469` (12,786,121 bytes).
- Effective export: `testFlightInternalTestingOnly=true`, `manageAppVersionAndBuildNumber=false`.
- Apple validation and upload both exited successfully. Both [GitHub regression jobs](https://github.com/davidganzha/SpyClash/actions/runs/39084428879) passed for the exact source commit.

## Audience and verification boundary

Build 186 is assigned only to the pre-existing private `LIMITLESS Internal QA` group, whose exact two members are David Ganzha and Dima Ianushevych. The final portal audit passed 16/16: no individual tester assignments, no other group receiving 186, no automatic all-build access, unchanged group membership and existing build assignments, and unchanged public App Store versions and attached builds. The audience and public-release baseline also remained unchanged between initial preflight and the refreshed pre-upload check.

The only delivery changes were uploading the approved internal-only binary and adding that build to the existing group. No backend, website, payment, secret, public App Store or App Review action was performed. Runtime backend configuration remains byte-identical to the committed configuration.

TestFlight availability does not prove tester installation, successful Apple sign-in, existing-account continuity or perceived speed. Those remain a fresh physical iPhone acceptance check. Build 185 failed on the user's iPhone; the build-186 fixture reproduces the reported navigation shape, not the exact production URL.

The sanitized receipt is [evidence/full-app/build186/testflight-delivery.json](evidence/full-app/build186/testflight-delivery.json). Full local source proofs, signed archive, IPA, validation/upload logs and portal readbacks are retained under ignored `.local/release186/`.
