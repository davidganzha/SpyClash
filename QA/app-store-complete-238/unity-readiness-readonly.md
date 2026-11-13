# Unity readiness — read-only audit, 13 November 2026

No messages, callback requests, deployments, secret updates, dashboard edits or
website publications were performed. Only public documentation/files, existing
local source, connected Gmail searches, the Unity browser/form and Supabase
secret names/digests were read. Secret values and digests are not recorded here.

## Verified current state

- Supabase project `bbkfsgnordtdiblgdzkg`: `UNITY_ADS_S2S_SECRET`,
  `UNITY_ADS_GAME_ID`, `UNITY_ADS_REWARDED_PLACEMENT_ID` and
  `SPYCLASH_REWARDED_AD_PROVIDER` are absent. The existing
  `SPYCLASH_REWARDED_GENERATION_ENABLED` digest matches exact `false`.
- `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED` is also absent; this is
  a separate billing prerequisite, not a Unity setting.
- `https://spyclash.com/app-ads.txt` returns HTTP 200 after a redirect to the
  existing Base44 public media file. Its entire seller content is the existing
  Google DIRECT entry. No Unity seller entries or `OWNERDOMAIN` are present.
- The existing Unity browser tab is on `auth.cloud.unity.com`, rather than the
  organization dashboard. The organization-specific seller list and account
  status could not be read from an authenticated dashboard in this audit.
- Gmail searches across all mail for Unity, the game/organization IDs,
  `Unity Ads Support`, `server-to-server` and `support-ads.unity` found no relevant
  sent request or activation reply. This does not establish the status of an
  external support portal or a different mailbox.
- Privacy candidate `/Users/davidganzha/Documents/SpyClash.worktrees/app-store-privacy-238`
  contains the reviewed four-language Unity/reward disclosure. It remains a
  prepared website change. App Store privacy answers and Unity seller entries
  are separate requirements.

## Remaining blocker and required configuration

The runtime reward flow cannot be activated yet: Unity-issued signing material
is absent on Supabase, and no provider activation or genuine signed callback has
been verified. The reviewed server bundles and enrollment schema/migration also
remain separate deployment prerequisites. A displayed ad or SDK completion is
not proof of a credited generation.

After provider setup and separately authorized deployment, both Supabase and
the canonical Base44 reward handler require:

| Setting | Required value |
| --- | --- |
| `SPYCLASH_REWARDED_AD_PROVIDER` | `unity` |
| `UNITY_ADS_GAME_ID` | `800429660` |
| `UNITY_ADS_REWARDED_PLACEMENT_ID` | `BP_Rewarded_iOS` |
| `UNITY_ADS_S2S_SECRET` | Actual secret supplied securely by Unity; never client-side or in Git |
| `SPYCLASH_REWARDED_GENERATION_ENABLED` | `true` only for the separately approved activation after prerequisites |

The callback is:

```text
https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv?provider=unity&game_id=800429660&placement_id=BP_Rewarded_iOS
```

The reviewed verifier expects exactly the fixed parameters above plus `sid`,
`oid` and `hmac`. It calculates HMAC-MD5 over all parameters except `hmac`,
sorted alphabetically and comma-separated:

```text
game_id=800429660,oid=<oid>,placement_id=BP_Rewarded_iOS,provider=unity,sid=<sid>
```

The opaque server-issued attempt token goes into SDK 4.21.0
`UADSShowConfigurationBuilder.with(customRewardString:)`. Ask Support to confirm
its mapping to callback `sid`, because the current S2S guide still illustrates
the older player metadata API. Keep the SSV endpoint public (`verify_jwt=false`)
and app-services authenticated (`verify_jwt=true`).

For sellers, use Unity Monetization Dashboard → Setup → Organization Settings →
Developer Website `https://spyclash.com/` → App-ads.txt → Show full list. Obtain
the exact list for organization `7972028227675`; do not derive seller IDs from
the game ID or copy another publisher's list. Preserve the Google entry and add
`OWNERDOMAIN=spyclash.com` with the authorized Unity list after approval.

## Verified support channel and prepared request

Unity's official S2S documentation links to the
[Unity Ads support form](https://support-ads.unity.com/s/ContactUs).
No recipient email was established from the official documentation. Although
the public web fetch showed a loading/CSS error, the actual Chrome form loaded
successfully without signing in. Its exact category route is:

1. Product Type: **Unity Ads Monetization**
2. Category: **Technical issue**
3. Sub-Category: **S2S Redeem Callbacks**

The resulting form accepts Name, Email, Game ID, Mediation Solution, Subject,
Description and optional attachments. Use Game ID `800429660`. The mediation
list has no None option; select **Other** and state that this integration uses
the direct Unity Ads SDK without mediation. The name and email must be the
user-approved reply identity. Only categories were selected to inspect this
flow; no contact details or message were entered and Submit was never pressed.
No CAPTCHA appeared before submission; a later challenge remains unverified.

The organization seller-list dashboard is a separate authenticated surface.
Its current Unity tab remains at login. The user must sign into their own Unity
account to read organization `7972028227675` under Setup → Organization Settings.
No credentials, terms, privacy-consent settings or organization data were changed.

Subject: Enable signed rewarded S2S callbacks — SpyClash iOS, Game ID 800429660

Hello Unity Ads Support,

Please enable signed server-to-server redeem callbacks for SpyClash iOS:

- Organization: `7972028227675`
- Project: `5f449fe3-a48f-4699-865a-2f588d20dfa7`
- iOS Game ID: `800429660`
- Rewarded placement: `BP_Rewarded_iOS`
- App Store ID: `6793534085`; bundle ID: `com.spyclash.ios`
- SDK: Unity Ads iOS 4.21.0
- Developer website: `https://spyclash.com/`
- Callback URL: `https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv?provider=unity&game_id=800429660&placement_id=BP_Rewarded_iOS`

Our app passes a server-issued opaque attempt token using
`UADSShowConfigurationBuilder.with(customRewardString:)`. Please confirm that
this value is delivered as `sid`, and that all callback parameters, including
the three fixed URL parameters, are included in the documented sorted HMAC-MD5
signature. Please provide the signing secret through a secure channel.

Each verified completed viewing grants one additional AI word-pack generation.
We do not grant a reward from the SDK completion alone. A processed callback,
including a retry of the same already-credited transaction, receives HTTP 200
with body `1`; no duplicate credit is granted. Please confirm this retry
acknowledgement and the supported method for validating a signed callback before
public activation, including whether test-mode callbacks are distinguishable.

Please also provide the exact app-ads.txt seller list for this organization, or
confirm the authenticated dashboard location. We will preserve our existing
Google seller entry and add Unity's full authorized list with
`OWNERDOMAIN=spyclash.com`.

We configure denied consent, opt-out and nonbehavioral treatment before SDK
initialization. Please identify the current SDK 4.21.0 Apple privacy disclosures
for that configuration; the general privacy-survey page describes an older data
snapshot. Please do not include signing secrets in public ticket replies.

Thank you,
David Ganzha

## Official references checked

- [S2S setup, signature and response](https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks)
- [Organization app-ads.txt seller list and OwnerDomain](https://docs.unity.com/en-us/grow/ads/optimization/app-ads-txt)
- [SDK 4.21.0 custom reward string API](https://docs.unity.com/en-us/ads-ios/4.21.0/sdk-integration/api/ios-api-swift)
- [Unity Apple privacy survey](https://docs.unity.com/en-us/grow/ads/privacy/apple-privacy-survey)

Tools available for this audit included Gmail search/read, public web retrieval,
read-only local browser tab inspection, and Supabase CLI secret-name/digest
listing. No connected Unity management tool was available. These tools do not
replace Unity Support activation or authenticated organization seller readback.
