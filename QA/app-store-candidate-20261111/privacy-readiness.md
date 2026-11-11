# Unity advertising privacy readiness — 11 November 2026

## Local candidate changes

`SpyClash/Resources/PrivacyInfo.xcprivacy` now includes the Unity disclosure
baseline below. Existing app declarations remain. The plist passes validation.
No SDK binary or third-party manifest was modified.

The inspected device manifest is
`/tmp/spyclash-unity-ads-226/SourcePackages/artifacts/unity-ads-swift-package/UnityAdsSDK/UnityAds.xcframework/ios-arm64/UnityAds.framework/PrivacyInfo.xcprivacy`.
It declares UserDefaults/CA92.1, FileTimestamp/C617.1 and DiskSpace/E174.1, but its
collected-data array is empty. These SDK API reasons do not need duplication in
the app manifest. The final archive must retain the framework's manifest.

The app manifest adds CoarseLocation, AdvertisingData, OtherUsageData,
PerformanceData and CustomerSupport. PurchaseHistory, DeviceID, ProductInteraction
and OtherDataTypes gain the corresponding advertising/analytics purposes.

Apple describes a manifest as the app/SDK data-type and required-API declaration;
its contents also inform the distribution privacy report. [Apple manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

## App Store Connect declaration draft

Retain existing app disclosures. Apply the following additions/expanded purposes
when preparing the advertising release. This is a draft, not a record of saved
App Store Connect values.

| Data category | Linked to user | Purposes added or retained for Unity |
| --- | --- | --- |
| Coarse Location | Yes, conservative default | Third-party advertising; analytics |
| Device ID | Yes | Third-party advertising; analytics |
| Purchase History | Yes | Third-party advertising; analytics |
| Product Interaction | Yes, existing app value | Third-party advertising; analytics |
| Advertising Data | Yes | Third-party advertising; analytics |
| Other Usage Data | Yes | Third-party advertising; analytics |
| Performance Data | Yes | App functionality; analytics |
| Other Data Types | Yes | App functionality; advertising; analytics |
| Customer Support | No | App functionality; ad-report submission |
| User ID | Yes, already declared | App functionality |

This follows the SDK 4.21.0 survey baseline, which still describes practices as
of August 2021. It does not enumerate a reduced data schema for denied consent.
Unity labels Coarse Location and Product Interaction linkage as not applicable;
the candidate does not assert anonymization and conservatively retains linkage.
[Unity Apple privacy survey](https://docs.unity.com/en-us/ads-ios/4.21.0/privacy/developer-consent/disclosures/apple-privacy-survey),
[Apple linkage guidance](https://developer.apple.com/app-store/app-privacy-details/).

The actual presenter sets consent=false, optOut=true and nonBehavioral=true before
initialization. Root `NSPrivacyTracking` remains false; this configures contextual
advertising, not zero collection. No ATT permission flow was added. [Unity consent behavior](https://docs.unity.com/en-us/ads-ios/4.21.0/privacy/developer-consent/solution/intro-to-dev-consent)

GoogleMobileAds remains bundled and its SDK manifest declares a tracking-capable
DeviceID collection. Do not edit that vendor manifest. The final privacy report
must be interpreted with the selected Unity release provider and actual dormant
Google path; this review does not claim a network-level no-tracking measurement.

## Prepared website update

Live read-only inspection found the deployed privacy page still saying the iOS
app includes no advertising SDKs. The new candidate requires removing that
statement. No website was edited or published.

`website-privacy-draft/PrivacyPolicy.jsx` is a four-language candidate with Unity
data handling, optional rewarded generation, denied-consent configuration,
server verification records and privacy controls. `website-privacy.patch` also
updates the existing revision-date expectations. It was prepared against the
owning website branch recorded in `baseline.json`; compare current source before
applying. The owning local checkout was left untouched. Deployment target is
`https://spyclash.com/PrivacyPolicy`.
The prepared patch passes `git apply --check` against that checkout. All three
existing website privacy-content tests pass against an isolated copy of the
candidate with the revised date expectations. A full website build was not run;
the checkout does not have its Babel parser installed.

## app-ads.txt

Read-only GET of `https://spyclash.com/app-ads.txt` returned HTTP 200 through the
existing Base44 public-storage redirect, with only the Google seller record:
`google.com, pub-5081830513960558, DIRECT, f08c47fec0942fa0`.
The App Store public lookup reports developer website `https://spyclash.com/`.

Before the Unity rollout, obtain the organization-specific full seller list from
Monetization > Settings > Organization > App-ads.txt, preserve the Google record,
add the actual Unity seller entries and `ownerdomain=spyclash.com`, and verify the
organization website setting is the same root domain. Never derive seller IDs
from the Unity Game ID. The reviewed Unity instructions discuss authorization and
ad demand; they do not establish that missing Unity rows are an App Store upload
blocker for this rewarded-only integration. [Unity setup instructions](https://docs.unity.com/en-us/monetization/dashboard/app-ads-txt/set-up-app-ads-txt),
[Unity demand explanation](https://docs.unity.com/en-us/monetization/dashboard/app-ads-txt/introduction-to-app-ads-txt-support).

No seller-list or production website change was performed. The support request
in [the prepared support request](../../release/UNITY-REWARDS-SUPPORT-REQUEST-228.md) includes the missing authoritative seller
entries and callback configuration. Sending it and publishing any changes require
the root agent to follow the current chat's explicit production/message approval.
