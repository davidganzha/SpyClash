# SpyClash 1.0.3 (173) — main app internal delivery

The user explicitly authorized the original **SpyClash**, build **1.0.3 (173)**, for **TestFlight Internal Only, David Ganzha only**, followed by Google and Apple sign-in checks on Ganzha. App Store submission was excluded.

## Verified artifact and delivery

- Source: unchanged application commit `83f41f68`, scheme `SpyClash-Supabase-Main-Candidate`, configuration `SupabaseRelease`.
- Main App Store Connect record `6793534085`; bundle `com.spyclash.ios`; embedded widget `com.spyclash.ios.widgets`. Both are 1.0.3 (173), signed with team `3Z64QKNL54` and existing valid App Store profiles. Effective main entitlements include Apple Sign In `Default`.
- IPA SHA256: `f1bd6b59985fa7b009e2af8a959bfe2f3711d7336b60a0d15fd1d3b01954e5b3`. Exported main Info.plist contains `TFInternalTestingOnly=true`; strict main/widget signatures pass. Public backend configuration and privacy manifest exactly match reviewed source. No local StoreKit configuration or scanned fixture credentials are packaged.
- Backend remains isolated Supabase `bbkfsgnordtdiblgdzkg`. Apple/Google are enabled; purchases, remote push and full account deletion remain disabled. No backend deployment, provider-console update, paid plan change or new secret was required.
- Apple validation and upload succeeded. Delivery/build ID: `2f3c219a-5eaa-4caa-84dc-bc4750819290`. Read-back confirms `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`; external testing is `NOT_APPLICABLE`.
- Assigned only to `Supabase Main Internal QA` (`f41d2529-7451-4605-857b-d257d34df23b`), whose sole tester is David Ganzha. No public link or automatic access, no other group assignment and no individual tester assignment. Existing QA groups and their older builds were retained.
- At 13 October 2026, 13:01 BST, the original App Store version records remained unchanged; 1.0.2 remains `READY_FOR_SALE`. No App Store version, review submission or release was created.

The general App Store release gate remains unchanged and intentionally rejects this test-backend candidate. This exact internal delivery was separately authorized and independently checked; it does not make the candidate eligible for App Store distribution or authorize production cutover.

Evidence: [delivery/read-back](evidence/full-app/build173/testflight-main-delivery.json), [independent IPA audit](evidence/full-app/build173/testflight-main-ipa-audit.json), [live authentication preflight](evidence/full-app/build173/testflight-main-live-auth-preflight.json).

## Physical authentication acceptance — pending

No physical install, launch or real Google/Apple completion is claimed by the upload. The user was asked to install **SpyClash** (without TEST) 1.0.3 (173) from TestFlight and complete Google sign-in on Ganzha. If saved credentials restore automatically, explicit logout and Google sign-in are still needed to test that provider.

1. Google: confirm return to the native main screen, the verified immutable account mapping, profile and existing history; relaunch and confirm restoration.
2. Apple: complete sign-in locally on the phone and verify the actual Base44 identity and its Supabase mapping. An equal contact email must not merge separate provider identities.
3. Return to the usual Google account and confirm its data remains intact.

Passwords, verification codes and Face ID stay on the iPhone. Do not remotely lock, restart or take over Ganzha for this flow. Record the user's observed result and server continuity separately; successful portal processing and a provider page are not successful authentication.
