# TestFlight startup crash — 1.0.4 (218)

Build 217 crashed during normal startup because its linked Google Mobile Ads SDK
validated an empty `GADApplicationIdentifier`, before the app's disabled-advertising
guard could prevent an explicit SDK start. The submitted iPhone report shows
`EXC_CRASH (SIGABRT)` and `GADApplicationVerifyPublisherInitializedCorrectly`,
61.9 ms after launch. A normal `SupabasePublicRelease` Simulator launch reproduced
the same stack and the missing-application-ID exception.

The release configuration now supplies Google's documented iOS sample application
ID as a valid SDK bootstrap value. Advertising remains disabled, the rewarded
unit remains empty, and the existing Release configuration rejects all sample
publisher IDs for ad requests. This does not activate advertising or change the
backend. `GADDelayAppMeasurementInit` remains enabled; these settings do not claim
that a linked SDK performs no internal initialization or network activity.

The release bundle gate now rejects an embedded Google Mobile Ads SDK with a
missing, blank, unresolved, malformed or non-string app ID, even with ads disabled.
It accepts the valid disabled configuration and leaves bundles without this SDK
compatible with existing checks.

## Verification

- Original exported build 217 fails the new app-ID gate with the expected reason.
- Full release gate suite: 78 passed, zero failures.
- Build 218 signed device archive and exported IPA pass the updated release gate.
- Apple archive validation: passed, no errors.
- Normal signed `SupabasePublicRelease` Simulator startup survived 57 seconds;
  forced termination and relaunch survived another 46 seconds with normal auth UI
  visible and no GAD/uncaught exceptions. No preview arguments or test host were used.
- Simulator installation passed the signature and Keychain-identity gate.
- Physical-device launch of the corrected TestFlight build remains a user check.

Version 1.0.4 is unchanged; build 218 is synchronized in `project.yml` and all
Xcode project configurations. This correction does not merge the separate game
header or online-intro branches.

Reference: [Google Mobile Ads iOS setup](https://developers.google.com/admob/ios/quick-start).
