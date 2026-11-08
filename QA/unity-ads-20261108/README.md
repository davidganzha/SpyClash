# Unity Ads visual test — 1.0.4 (226)

## Scope

Unity Ads 4.21.0 is integrated through Unity's official Swift package. This change
adds an explicitly enabled Debug-only viewing experiment. It does not integrate
Unity with generation-credit issuance or change the live AdMob/server flow.

The SDK initializes lazily after a button press with `testMode: true`, consent
disabled, user opt-out enabled, and nonbehavioral treatment enabled. Release
excludes the presenter and controls; its configuration always fails closed.

## Open the test

Build the `SpyClash` scheme in Debug with `CODE_SIGNING_ALLOWED=YES`, install using
`scripts/install-ios-simulator-app.py`, and launch with:

- `--spyclash-unity-ad-preview`: opens the viewing screen without a mock account.
  "Return to SpyClash" restores the normal signed-in or welcome flow.
- `--spyclash-test-unity-ads`: keeps the normal app flow and adds the Unity viewing
  control in generation setup.

Both modes require valid build-time `SPYCLASH_UNITY_TEST_GAME_ID` and
`SPYCLASH_UNITY_TEST_AD_UNIT_ID` values. The default `14850` / `rewardedVideo`
pair comes from Unity's public iOS example. The defaults were accepted by the
service during this check; they are not a guarantee of continued sample access.
An optional local `SPYCLASH_UNITY_TEST_ADS_ENABLED=YES` build setting exposes the
integrated control without launch arguments. None of these enable Release ads.

## Verification

- Signed Simulator build passed on iPhone 17 / iOS 26.5.
- 32 focused unit tests passed: Unity configuration gates, existing AdMob gates,
  and generation reward store behavior. No failures or skips.
- SDK logs confirmed initialization in test mode, successful network ad load,
  and full-screen display of Unity's own test creative.
- Observed the video, end card, and return to the app after completion.
- Repeated viewing in the same app session loaded and completed successfully
  without a second SDK initialization. The result label appeared and the watch
  button became available again.
- This test creative used two sequential close screens. The recording includes
  the actual SDK experience; it is not evidence of real advertiser inventory.
- The SDK's reward callback does not issue any generation credit.
- A separate source review found no actionable issues.

Local evidence: `output/unity-ads-226-20261108/` (video and screenshots).
Simulator UDID: `CEB46208-6333-4293-ABCE-47CF25B47591`.

Physical-device playback, real advertiser inventory, and production monetization
are not validated by this test. No TestFlight upload or production action was made.

## Sources

- https://github.com/Unity-Technologies/Unity-Ads-Swift-Package (pinned to 4.21.0)
- https://github.com/Unity-Technologies/unity-ads-ios/blob/master/Example/UnityAdsExample/ViewController.m
