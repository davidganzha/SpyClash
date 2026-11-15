# SpyClash 1.0.4 release preparation — 15 November 2026

App Store Connect lists iOS 1.0.4 as `PREPARE_FOR_SUBMISSION` with manual
release and build 238 attached. Apple has processed build 238 as `VALID`.
The exported IPA matches the upload hash and passes the signed release
bundle check against commit `0f78ae22`. Build 240 is the repository version
for the server and site changes below. The iOS release candidate is **238**.

The monthly LIMITLESS product `com.spyclash.ios.limitless.monthly` (Apple
ID `6825982027`) is one month at US $2.99. Its review note is present and its
state is `MISSING_METADATA` with no review screenshot. The draft's en-US
listing uses `https://spyclash.com/` and names rewarded ads. Its review
credentials are populated. The current review instructions still need the
billing and version updates. The draft age-rating declaration currently
answers `advertising=false`.

## Unity and the signed callback

[Unity ticket 00945449](https://support-ads.unity.com/s/cases?id=500Qv00000lpu0RIAQ)
confirms that signed S2S callbacks are enabled for iOS Game ID `800429660`
and gave us the server signing key. The ticket says all URL parameters
except `hmac` enter the signature. It points to `setServerId`, the legacy API.
The SDK 4.21 header deprecates that API in favor of
`UADSShowConfigurationBuilder.with(customRewardString:)`, which both the
[SDK 4.21 callback guide](https://docs.unity.com/en-us/ads-ios/4.21.0/sdk-integration/s2s-redeem-callbacks)
and build 238 use. A device viewing must verify that the live Unity callback's
`sid` matches the exact issued attempt.

Supabase project `bbkfsgnordtdiblgdzkg` currently runs `app-services` v27,
`full-game-core` v17 and `rewarded-generation-ssv` v4. The public rewarded
flag reads `false`, and Unity provider, game, placement and secret settings
are absent. The deployed callback endpoint verifies HMAC-MD5 and returns
HTTP 200 with `1` after crediting the issued attempt. A retry of that exact
already-credited event acknowledges the original grant. The
callback still has to be observed from Unity on a completed device viewing.

## Prepared artifacts

- [App Store metadata review](../QA/app-store-metadata-238/privacy-and-review-diff.md)
  contains the reviewed privacy label changes, editable advertising answer and
  scoped review-note replacement. Use the updated version and QA state below
  when applying the note.
- [app-ads.txt](website-app-ads-240/app-ads.txt) includes all 163 rows from
  Unity organization `7972028227675`, the live Google DIRECT row and
  `OWNERDOMAIN=spyclash.com`. Unity's list provides a shorter certification
  ID for `dauup.com`. The file preserves the exact vendor value. The local
  site archive adds the root text file to the five currently published assets
  after verifying their live hashes. The current path redirects to an older
  Google-only file. Unity's Developer website field is blank and its crawler
  reports `badUrlForm`.
- [Package manifest](website-app-ads-240/manifest.json) records the exact
  changed-file hashes and site archive. The server packages under
  `.local/app-store-preflight-240/` start from the read-back 238 packages.
  Supabase `app-services` changes two files. Base44
  `generateWordPack` changes three and `generationRewardAction` changes one.
  The existing enrollment schemas and SSV gateway support the pilot.

## Verification

The assembled server packages passed strict Deno type checks, 35 native
PostgreSQL integration checks and 28 Base44 handler checks. The source
membership and Unity signature unit suites passed 11 more checks. The pilot
tests prove account-scoped enrollment, three free generations, idempotent
signed rewards, and a single credit spend. The local site archive served
the exact seller file with HTTP 200 and content type `text/plain`.
The TestFlight purchase, restore and actual Unity delivery remain device
checks. The connected iPhones were unavailable during this preparation.

## Release sequence

1. Recheck the live package baselines. With explicit approval, deploy the three
   pilot packages to Supabase `bbkfsgnordtdiblgdzkg` and Base44 app
   `69a0e57fa939f578082f8091`. Set `SPYCLASH_REWARDED_AD_PROVIDER=unity`,
   `UNITY_ADS_GAME_ID=800429660`, `UNITY_ADS_REWARDED_PLACEMENT_ID=BP_Rewarded_iOS`
   and the ticket key as `UNITY_ADS_S2S_SECRET` in server secret storage.
   Use `SPYCLASH_REWARDED_GENERATION_PILOT_USER_IDS` with the authenticated
   native user IDs in Supabase and authenticated Base44 user IDs in Base44.
   Keep the public rewarded flag `false` through the pilot. An empty pilot
   list cancels new offers while already issued signed callbacks can settle.
2. With explicit approval, publish the static `app-ads.txt` candidate on
   the canonical site and set Unity's Developer website to
   `https://spyclash.com/`. Verify that the public path serves the new exact
   text and check the Unity crawler. Inspect the existing redirect if it
   takes precedence over the new file.
3. Capture the genuine build 238 LIMITLESS screen after the monthly price
   loads. Upload it to subscription `6825982027` after approval. Enable
   `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED=true` in the approved
   backends for TestFlight QA. Keep legacy weekly ownership and restore paths.
4. On TestFlight 238, verify a non-LIMITLESS pilot account on each supported
   backend starts with three daily generations, receives one credit after
   a genuine completed Unity viewing and spends it once. Check a non-pilot
   and a LIMITLESS account. Verify monthly purchase, server entitlement,
   restore and relaunch with Apple sandbox credentials. Verify restoration
   of an existing weekly entitlement under its original account. Check
   onboarding, sign-in, multiplayer start and return, account deletion and
   the review account before submission.
5. Once the device checks pass, apply the approved App Store privacy details,
   advertising answer and reviewed instructions. Coordinate the public
   rewarded flag with review so the submitted feature and description match.
   Submit iOS 1.0.4 (238) and the monthly subscription together after approval.
   The version uses manual public release after Apple review.

## Review instructions draft

Replace the outdated version and billing paragraphs in the existing app
review notes. Keep the working demo login and other instructions.

> This submission is SpyClash 1.0.4 (238). Sign in with the supplied demo
> account and open LIMITLESS to see the monthly auto-renewing subscription
> and its localized App Store price. Choose Subscribe to test purchase or
> Restore Purchases to restore access. The app continues to recognize existing
> weekly subscriptions. Purchase access is verified by the server.

Add after the rewarded flow is available to the reviewer and tested:

> On a free account, open AI word-pack generation. After the three daily
> generations, choose to watch an optional rewarded ad. A completed viewing
> adds one generation after server confirmation. LIMITLESS accounts have
> unlimited generations.
