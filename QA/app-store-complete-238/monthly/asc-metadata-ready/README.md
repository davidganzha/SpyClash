# Monthly subscription and App Store 1.0.4 draft preparation

Read-only audit and local payload preparation on 13 November 2026. No ASC
write, upload, submission, release, price change, or agreement acceptance was
performed. The build was already uploaded separately; do not upload it again.

## Live-read status

Fresh readbacks are available again after the Account Holder accepted the
updated agreement. Browser reload confirms the correct team, Program License
Agreement issued 29 October and accepted 13 November, and both Paid Apps and
Free Apps agreements active. The ASC warning disappeared. Early API retries
briefly remained blocked while the change propagated; no further agreement
action is indicated by the current evidence. `asc-readback-status.json` contains
sanitized current observations and private-snapshot hashes.

Current API readbacks at 10:12–10:14 UTC: monthly `6825982027`, ONE_MONTH,
MISSING_METADATA, USA USD 2.99; subscription version
`ad15b177-6482-4129-9c47-3ebfafb0a633`, PREPARE_FOR_SUBMISSION;
en-US/es-ES/ru localizations; no review note or review screenshot. No App Store
version 1.0.4 exists. Build238 `0aa55760-da71-4622-a1b3-e3ecc9aa673f` is VALID,
APP_STORE_ELIGIBLE, and belongs to the 1.0.4 IOS pre-release train. Subscription
group22256419 version1 is APPROVED. All four prior app review submissions are
COMPLETE.

## Exact approval scope that is ready

After successful fresh readback, one explicit approval may cover the following
ASC metadata preparation only. All payloads are local JSON, not an execution
script. Their names identify the request order; fields with `${...}` are runtime
IDs obtained from an authorized response and must never be sent literally.

| Operation | Endpoint | Local body |
| --- | --- | --- |
| Add the monthly review note | PATCH /v1/subscriptions/6825982027 | 01-monthly-review-note.json |
| Add missing Ukrainian monthly localization to the verified editable version | POST /v2/subscriptionLocalizations | 02-monthly-uk-localization.json |
| Create iOS 1.0.4 with manual release and existing build238 | POST /v1/appStoreVersions | 03-app-version-1.0.4.json |
| Update English fields on that new version | PATCH /v1/appStoreVersionLocalizations/{newVersionEnglishLocaleID} | 04-app-en-localization-patch.template.json |
| Only if the new version has no English localization, create it instead | POST /v1/appStoreVersionLocalizations | 04-app-en-localization-create.template.json |

The description and What's New are assembled exactly from the existing
`release/APP-STORE-238-METADATA.md` draft. Existing English keywords, support URL,
marketing URL and promotional text are carried forward. The existing Apple
renewal terms, account deletion note, privacy URL and Standard EULA remain.
The description is 1,952 characters; the review note is 741 characters. The
Ukrainian name and description fit the 30/55-character limits.

The full-release copy includes three free generations and optional rewarded ads.
It may be saved as a draft within an explicit metadata approval, but must not be
submitted/published unless the reviewed reward service is activated and accepted.
This preparation does not enable the monthly server flag or rewards and does
not authorize their activation. The monthly server flag can be separately named
in the same approval request if its exact deployed prerequisites are verified.

Before any write, read monthly product, versions and version localizations,
review screenshot, existing app versions, and build238 with pre-release version.
If 1.0.4 already exists, reuse only after inspecting its state and relationship;
do not issue a duplicate create. If Ukrainian already exists, compare rather
than create a duplicate. If subscription version1 is no longer editable, stop
and prepare a revised version operation rather than silently altering another
review cycle. Verify the current USD price; no pricing request is included.

After metadata writes, read back the monthly note, all four version-locales,
1.0.4 releaseType MANUAL, linked build238 and its 1.0.4 pre-release train, and
English fields. Check new-version screenshot sets and review contact fields;
do not assume that creation inherited them from 1.0.3. Preserve existing listing
assets unless an exact replacement is reviewed. These payloads do not add any
item to App Review or mark any submission submitted.

## The review screenshot is still an actual missing artifact

A subscription's in-app review screenshot stays on the parent product through
`/v1/subscriptionAppStoreReviewScreenshots`. The version `image`/`images` and
`/v2/subscriptionImages` describe optional subscription promotion artwork; a
null version image does not itself establish a missing paywall screenshot.
[Apple subscription review workflow](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review)
[Apple version workflow](https://developer.apple.com/documentation/appstoreconnectapi/working-with-subscription-versions)

Fastest reliable capture route: install the already uploaded TestFlight238,
sign in normally, open LIMITLESS, wait for the monthly StoreKit price, and capture
the unobstructed screen. The price is localized; do not edit it to show USD if the
phone uses another storefront. A purchase is not needed merely to take this
screenshot. It still does not prove successful purchase or restoration.

The DEBUG preview route deliberately skips `store.loadProduct()` in PricingView,
so it cannot provide a genuine price. A normal local Xcode run using
`StoreKit/SpyClash-Monthly.storekit` would be acceptable as a clearly disclosed
local-testing capture if the actual Product loads, but that path is currently
unproven: six prior StoreKit tests stopped at a `notEntitled` canary. No fabricated
price, image generation, composite image, or modified text is acceptable.

After a real capture exists, inspect it, record its SHA-256, PNG dimensions,
actual byte count and MD5. Then the exact file can be authorized for upload:

1. Fill the actual integer fileSize in `05-review-screenshot-reservation.template.json`
   and POST /v1/subscriptionAppStoreReviewScreenshots.
2. Upload exact byte ranges using only Apple's returned uploadOperations.
3. Fill the reservation ID and actual MD5 in
   `06-review-screenshot-commit.template.json`; PATCH the reservation endpoint.
4. GET the screenshot until assetDeliveryState is COMPLETE, and verify that the
   monthly product relationship points to it. Keep upload URLs private.

[Apple asset upload contract](https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect)

## Review submission remains a later approval

When metadata, screenshot, server activation and device acceptance are complete,
use a draft review submission with `appStoreVersion` and `subscriptionVersion`
items for the intended combined review. Apple currently supports the versioned
review-submission workflow. The existing weekly subscription is already approved;
this is an additional subscription. Its subscription group version1 is currently APPROVED, so no group item is
needed while the group metadata remains unchanged; verify again before submission. Do not change the weekly
product, its subscribers, pricing, or restoration.

No review-submission request is included in these payloads. `submitted:true`
and public release each require their own explicit authorization.
[Apple submission guide](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)

## Separate internal TestFlight assignment ready for approval

Build238 is READY_FOR_BETA_TESTING and currently belongs to no beta group.
Existing internal groups are LIMITLESS Internal QA
`47a13858-b43b-44a1-bf3e-285722cec320` and Supabase Main Internal QA
`f41d2529-7451-4605-857b-d257d34df23b`; both have hasAccessToAllBuilds=false.
The narrow proposed action is only to give the existing LIMITLESS Internal QA
group access to this already uploaded build, without adding testers or changing
external/public distribution. autoNotifyEnabled is currently true, so group
members may receive the normal TestFlight notification.

After explicit approval, POST
`/v1/builds/0aa55760-da71-4622-a1b3-e3ecc9aa673f/relationships/betaGroups`
with `07-testflight-limitless-internal-group.json`. Verify using
`GET /v1/betaGroups?filter[builds]=0aa55760-da71-4622-a1b3-e3ecc9aa673f`.
The build betaGroups relationship itself does not support GET; the direct
relationship GET was rejected without any mutation. Apple permits only one
relationship filter on the list query, so do not combine app and builds filters.

[Apple beta group access endpoint](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-builds-_id_-relationships-betagroups)
[Apple beta group list endpoint](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-betagroups)
