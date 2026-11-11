# Unity support request — ready to send, not sent

Subject: Enable signed server-to-server rewarded callbacks for SpyClash iOS (Game ID 800429660)

Hello Unity Ads Support,

Please enable server-to-server redeem callbacks for our SpyClash iOS app:

- Organization: `7972028227675`
- Project: `5f449fe3-a48f-4699-865a-2f588d20dfa7`
- iOS Game ID: `800429660`
- Rewarded placement: `BP_Rewarded_iOS`
- App Store app: `6793534085`; bundle ID: `com.spyclash.ios`
- Developer website: `https://spyclash.com/`
- Callback URL: `https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv?provider=unity&game_id=800429660&placement_id=BP_Rewarded_iOS`

The app sends a server-issued opaque attempt token as the SDK custom reward string
(`sid`). Each verified completed viewing grants exactly one additional AI word-pack
generation. The SDK completion alone never grants a reward.

Please provide the callback secret hash securely and confirm that the `provider`,
`game_id`, and `placement_id` URL parameters are included in the sorted HMAC-MD5
signature along with `sid` and `oid`, as described in your S2S documentation. Our
endpoint acknowledges a successfully processed callback, including a retry of
the same transaction, with HTTP 200 and body `1`.

Please also confirm the supported way to validate a signed callback before public
release, and whether test-mode callbacks can be distinguished from live inventory.

For app-ads.txt, please point us to the exact authorized seller entries for this
organization. We will preserve our existing Google entry and publish Unity's full
organization-specific list with `OWNERDOMAIN=spyclash.com`.

Our integration sets denied consent, opt-out and nonbehavioral flags before SDK
initialization. Please confirm any differences in the required Apple privacy
disclosures for this configuration versus the SDK 4.21.0 privacy survey. Please
do not include signing secrets in public ticket replies.

Thank you,
David Ganzha

## Preparation status

This request is not an activation receipt. The new callback implementation is
prepared locally; it must be deployed with explicit approval before a provider
verification request. The support-issued signing secret must be stored only in
the server configuration, never in Git, the iOS application, or this document.

Reference: https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks
