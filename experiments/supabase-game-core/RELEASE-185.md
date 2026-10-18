# SpyClash 1.0.3 (185): internal TestFlight delivery

Delivered on 18 October 2026 after explicit approval in the current chat to sign and upload build 185 only for David and Dima. App Store Connect verified `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, and external testing `NOT_APPLICABLE` at **00:31:12 UTC / 01:31:12 London**.

## Delivered change

Apple session completion remains invisible after the native Apple authorization sheet. The patch fixes a reproduced defect where an incidental child frame terminated the main attempt with H03, and adds bounded diagnostics for other rejected navigation shapes. See [APPLE-SIGN-IN-185.md](APPLE-SIGN-IN-185.md) for the 69/69 focused tests and remaining physical-device uncertainty.

The exact source is `a9a29283caab1599f4436cb96f16822ef8f1af99` on `davidganzha/supabase-game-core`. Main app and widget are both 1.0.3 (185). A frozen copy of all 1,300 tracked files was used; only six existing signing settings in the two project files differed. Source verification passed 11/11 before and after compilation, signed archive verification passed 17/17, and independent exported IPA verification passed 19/19. Preserved copies match the original artifacts byte for byte.

- App: `com.spyclash.ios`; App Store Connect app `6793534085`.
- Build ID: `832e1ec2-b920-4b8a-81f6-4a79f30d70a9`.
- IPA SHA-256: `56163704d059b1feae89f5339dedda8accb2b75db8265bf42515133f96b7173e` (12,770,348 bytes).
- Effective export: `testFlightInternalTestingOnly=true`, `manageAppVersionAndBuildNumber=false`.
- Apple validation and upload both exited successfully. Both [GitHub regression jobs](https://github.com/davidganzha/SpyClash/actions/runs/39082363379) passed for the exact source commit.

## Audience and verification boundary

Build 185 is assigned only to the pre-existing private `LIMITLESS Internal QA` group, whose exact two members are David Ganzha and Dima Ianushevych. The final portal audit passed 16/16: no individual tester assignments, no other group receiving 185, no automatic all-build access, unchanged group membership and existing build assignments, and unchanged public App Store versions and attached builds.

The only delivery changes were uploading the approved internal-only binary and adding that build to the existing group. No backend, website, payment, secret, public App Store or App Review action was performed. Runtime backend configuration remains byte-identical to the committed configuration.

TestFlight availability does not prove tester installation, physical Apple sign-in, existing-account continuity or perceived speed. Those remain a fresh iPhone acceptance check. The exact branch responsible for the original build 184 H03 is still unconfirmed.

The sanitized receipt is [evidence/full-app/build185/testflight-delivery.json](evidence/full-app/build185/testflight-delivery.json). Full local source proofs, signed archive, IPA, validation/upload logs and portal readbacks are retained under ignored `.local/release185/`.
