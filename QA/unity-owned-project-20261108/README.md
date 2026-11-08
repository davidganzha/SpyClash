# SpyClash owned Unity Ads preview — 1.0.4 (227)

## Unity dashboard

Created the SpyClash project and iOS app in the existing Unity organization,
linked to the public App Store listing. No developer-data sharing opt-in was enabled.
The app audience follows the existing SpyClash privacy policy: general audience,
not directed at children.

- Project ID: `5f449fe3-a48f-4699-865a-2f588d20dfa7`
- iOS app ID: `86347700-ced4-4384-a35e-9c3ad61a9990`
- App Store ID: `6793534085`; bundle: `com.spyclash.ios`
- Game ID: `800429660`
- Rewarded placement: `BP_Rewarded_iOS` (active)
- Dashboard: https://cloud.unity.com/organizations/7972028227675/monetization-v2/placements

These are public integration identifiers, not credentials. No Stats API key was created.

## Local preview

The build now uses the owned Game ID and placement. Existing preview flags still
request test ads. A separate exact `--spyclash-unity-live-ad-preview` launch argument
opens the Debug-only screen and requests live inventory with `testMode: false`.
Release, normal Debug launch, fixture preview, invalid IDs and the public Unity
sample Game ID cannot enable live delivery. The SDK initializes only after the
Watch button is pressed. Consent remains false, opt-out and nonbehavioral treatment
remain enabled. This preview never grants generation credits or calls the reward
backend. Current public/TestFlight apps and their ad settings were not changed.

## Verification

- 36 focused tests passed, zero failures/skips: Unity configuration, existing
  AdMob configuration and generation reward store.
- Signed Simulator build and installation passed; Keychain identity verified.
- Build: `1.0.4 (227)`, iPhone17 / iOS26.5,
  simulator `CEB46208-6333-4293-ABCE-47CF25B47591`.
- Runtime log confirms SDK 4.21.0 initialized with the owned Game ID in production
  mode and loaded/presented `BP_Rewarded_iOS` successfully without mediation info.
- Observed an actual Royal Match advertiser creative, rather than Unity's branded
  sample. The SDK still shows a developer App Store overlay in Simulator.
- First live creative finished successfully according to the SDK callback.
- Subsequent attempts loaded successfully but hit SDK show timeout code 2 after 10s.
  The same failure reproduced after app relaunch and with test creatives, so it
  was not evidence of unavailable ad inventory. The presenter remained the
  visible key UIWindow's root UIHostingController, with no presented overlay.
- Restarting only the dedicated Simulator restored SDK `showDidStart` and test
  creative playback without changing app data or Unity dashboard settings.
- After Simulator recovery, two live creatives opened and completed consecutively
  in one app process with no second initialization: Kingshot, then a different
  drink-sorting creative. Both emitted `showDidStart`, reward (ignored) and
  completed callbacks; the app returned to its viewing screen.
- Recovery is evidence of a Simulator/environment issue, not proof of its exact
  root cause or physical-device stability. No SDK downgrade, arbitrary delay,
  cache wipe or network/proxy configuration change was made.
- Added Debug SDK/presentation diagnostics and distinct preparation vs opening
  error messages; no speculative retries or rewards changes were added.
- A read-only source review found no actionable issues.

Local evidence: `output/unity-owned-227-20261108/`.
Physical iPhone behavior and general inventory/fill are not established by these
Simulator displays. The agent did not install advertised products or click install CTAs.
The current public app and TestFlight builds were not replaced or uploaded.

The 36 focused tests preceded the final diagnostics/error-copy-only update; the
final signed build and runtime verification passed afterward. Final installed
bundle SHA-256: `fd37852b945f0ebf8dc0468e518e28d8c0b07777cf73b9160f7cfa4543e3a23f`.

Video evidence: `royal-match-excerpt.mp4` is the first 45seconds of the original
recording; `kingshot-preview.mp4` records part of Kingshot through its close and
return to SpyClash. Original recordings are retained locally.

## Sources

- https://docs.unity.com/en-us/ads-ios/4.21.0/sdk-integration
- https://docs.unity.com/en-us/grow/ads/Changelog
- https://docs.unity.com/en-us/monetization/dashboard/add-an-app
- https://docs.unity.com/en-us/grow/ads/references/faq
