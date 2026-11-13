# Read-only release metadata comparison — build238

Observed 13 November 2026. These additional changes are proposals only; none of
the privacy labels, age-rating answers or app-review notes below were saved.
The separately approved monthly metadata/version/TestFlight work is complete.

## Privacy labels

The App Store Connect page shows a published declaration from two months ago,
11 collected data types, and no separate draft or Publish/Save action. The
published privacy URL is already `https://spyclash.com/privacypolicy`. Its current
category, purpose and linkage values are captured in `privacy-current-ui.json`
and `privacy-label-proposal.json`; no private account information is included.

The exact238 IPA hash was verified against the upload artifact. Its app manifest
matches the frozen source and declares16 types. The prepared advertising privacy
baseline maps to this precise additive label change:

| Category | Change | Linkage | Final purposes |
| --- | --- | --- | --- |
| Coarse Location | Add | Linked | Third-party advertising, Analytics |
| Advertising Data | Add | Linked | Third-party advertising, Analytics |
| Other Usage Data | Add | Linked | Third-party advertising, Analytics |
| Performance Data | Add | Linked | App functionality, Analytics |
| Customer Support | Add | Not linked | App functionality |
| Purchase History | Expand purposes | Keep linked | App functionality, Third-party advertising, Analytics |
| Device ID | Expand purposes | Keep linked | App functionality, Third-party advertising, Analytics |
| Product Interaction | Add third-party advertising | Keep linked | App functionality, Analytics, Third-party advertising |
| Other Data Types | Expand purposes | Keep linked | App functionality, Third-party advertising, Analytics |

Preserve the other seven existing categories and their purposes/linkage. Tracking
stays No for all types. The shipped Unity presenter sets consent=false,
optOut=true and nonBehavioral=true before initialization; its source matches the
archive source manifest. Shipped configuration selects Unity, so the Google ad
request path's provider guard is disabled. There is no ATT usage description.

The binary still includes GoogleMobileAds and UserMessagingPlatform manifests;
Google's DeviceID entry is tracking-capable. Those vendor manifests were not
changed. The proposed labels reflect the selected configuration and prepared
Unity disclosure baseline, not a network-level proof of every SDK behavior.
Unity's survey is for SDK4.21.0 but still describes its August2021 baseline;
it does not provide a reduced denied-consent collection table. Preserve this
limitation rather than describing contextual ads as zero data collection.

[Apple requires disclosures for integrated third-party practices](https://developer.apple.com/app-store/app-privacy-details/).
[Unity's data-category survey](https://docs.unity.com/en-us/ads-ios/4.21.0/privacy/developer-consent/disclosures/apple-privacy-survey).

Publishing labels affects the live app privacy declaration; it is a separate
production operation from merely keeping1.0.4 as a draft and needs explicit
approval. No label editor or Publish action was used during this audit.

## Age-rating advertising answer

Both the published and editable declarations currently have advertising=false.
For the intended optional-video-ad release, propose changing only the editable
1.0.4 declaration `08a99022-5f91-48eb-bde3-bd658f2c860e` to advertising=true.
`age-rating-advertising-proposal.json` contains that single-attribute payload;
all other answers remain intact. Apple computes the resulting regional ratings.

[Apple defines advertising to include video/playable ads](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/).
[The API advertising field is Boolean](https://developer.apple.com/documentation/appstoreconnectapi/ageratingdeclarationupdaterequest/data-data.dictionary/attributes-data.dictionary).

## Existing review information and listing assets

All four required review contact fields are populated and identical to1.0.3.
Demo-account login is required and both name/password fields are populated;
only presence was inspected, no credential was printed or saved. Those
credentials were not login-tested. Five listing screenshots were inherited,
are COMPLETE, and retain the same filenames, byte sizes and checksums.

The carried-over app-review notes are stale: their opening references1.0.3(200)
and the billing paragraph describes weekly new checkout. The public replacement-only proposal in
`app-review-notes-proposal.json` contains only the old/new version sentence and
subscription paragraph. Full inherited notes are retained only in ignored local
private storage; apply the two replacements to a fresh private read:1.0.4(238), new monthly checkout and preserved weekly
restoration. All remaining notes and contact fields are retained. This proposal
does not claim that monthly purchase, ad delivery or rewards were accepted on a
phone. Once the reward provider is activated and accepted, add accurate review
steps before submitting; do not claim inactive functionality is available.

The monthly subscription's genuine review screenshot is still missing. It must
be captured from the actual monthly paywall with a loaded StoreKit price. This
is separate from the five existing public App Store listing screenshots.

## Remaining approval boundary

A subsequent explicit approval can cover: the exact16-category privacy label
publication, the single draft advertising flag, and the two scoped app-review
note replacements. Review screenshot upload needs its actual inspected file.
App Review submission and public release remain separate later approvals.
