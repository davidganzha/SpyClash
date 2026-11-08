# Integrated test advertising — build 225

The signed Debug Simulator app is the ordinary SpyClash app: normal sign-in, navigation, games and generation. Google sample ads can be opened from the shared generation allowance component in the word-pack editor, local game setup and online-room theme setup. No UI preview account or direct preview destination is used.

## Local build

Build the `SpyClash` scheme in Debug with signing enabled and `SPYCLASH_INTEGRATED_TEST_ADS_ENABLED=YES`. The value is embedded in Info.plist so ordinary relaunches retain the test control without launch arguments. Repository defaults remain NO. The optional `--spyclash-test-ads` flag is also supported.

The control requires Debug, Simulator and the exact official Google sample application/unit pair. It is excluded from Release and physical-device UI, owned AdMob configurations and UI previews. Ads are requested only after tapping the button. The view uses the established monospaced typography and localized English, Russian, Spanish and Ukrainian copy.

The test presenter passes fixed local identifiers, never account data or a server-issued reward token. Completion reports a test viewing only: no prepare/claim request, server reward, local simulated credit, quota change or generation consumption is performed. A pending real reward blocks the local test button. Cancellation, account changes and generation startup cancel the local viewing operation.

## Verification

- Signed Debug build 1.0.4 (225) succeeded.
- Installation gate passed signature, Simulator Keychain identity and installed-content digest checks on `SpyClash Theme Ideas QA` (`F1165ACF-09E1-4249-8732-4E9F67CB2BFE`).
- Installed app SHA-256: `88ce7ad5c714f3e2120afa771e3358b711038d2ed327fccc74f0395aa6685c14`.
- Built Info.plist has the integrated-test flag YES and the official Google sample IDs. Launched without preview or test arguments.
- 29 focused XCTest checks passed: 14 configuration, 12 reward-store and 3 presentation-transition tests. Result: `/tmp/SpyClash-IntegratedAds-225-Tests-20261108.xcresult`.
- Independent source review and git whitespace checks passed.
- Normal-app runtime currently opens the sign-in screen. In-game viewing, dismissal and repeat viewing await the user's normal account sign-in; the earlier isolated preview check is not claimed as this integration's runtime evidence.

No production configuration, deployment, TestFlight or App Store operation was performed. Real rewarded credits still require the separately configured owned-unit and server-verification flow.
