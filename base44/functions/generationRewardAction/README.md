# Generation rewards

Prepared integration; no environment has been deployed or activated by these changes.

`SPYCLASH_REWARDED_GENERATION_ENABLED=true` makes the new policy available; only persistently enrolled accounts use three free generations per UTC day and separate non-expiring reward credits. Actual verified Apple/Stripe/admin LIMITLESS access stays unlimited. The flag does not change unrelated CASADA benefits. The default is disabled and preserves existing generation access.

`ADMOB_REWARDED_AD_UNIT_ID` must be the app's own full AdMob unit ID. Google's public sample units are deliberately rejected for server credits. Configure the unit's reward as **1 generation**, and configure its SSV callback to this function's public GET URL. The iOS SDK must pass the exact `custom_data` and `user_id` returned by `prepare`. AdMob account creation and production configuration are separate activation steps.

Authenticated POST actions:

- `status` returns `enabled`, `unlimited`, `daily_limit`, `free_remaining`, `bonus_credits`, `resets_at`, and `ad_available`.
- `prepare` requires a stable UUID `request_id` and returns `attempt_id`, `custom_data`, `ad_unit_id`, `user_id` (also `ssv_user_id`) plus the status fields. It rejects if a free or previously earned generation is already available. A repeated request ID recovers the same attempt.
- `claim_status` requires `attempt_id`, scoped to the signed-in account, and returns `state` (`pending`, `earned`, or `expired`) plus status. Pending attempts report expired after 24 hours and five minutes; their records remain available for delayed valid SSV delivery.

GET is an unauthenticated-user provider callback. It verifies Google's ECDSA signature before granting anything and uses canonical Base44 service-role routing. Google does not need to supply app/user authentication headers. Live gateway and SSV delivery must still be verified with the eventual AdMob account before activation; current integration tests use the real handler and synthetic Google-compatible signatures with a local SDK/database fixture.

State transitions: `pending -> earned -> reserved -> spent`; a definitive generation failure restores `reserved -> earned`. Reservations use the existing per-account generation coordinator and deletion-opposing lifecycle guard. Exact-state compare-and-set plus read-after-write reconciliation prevent duplicate callback credits, double spending, and duplicate refunds. Unknown provider outcomes remain reserved and cannot be retried as a fresh paid operation; a durable saved generation replay settles its original credit. Account deletion removes reward records, and its lifecycle marker prevents late callbacks from recreating them.

Validation (no live requests):

```sh
npx --yes deno@2.9.5 test --no-config --no-lock --allow-env --deny-net base44/functions/generationRewardAction/admob-ssv_test.ts base44/functions/generateWordPack/generation-rewards_test.ts
npx --yes deno@2.9.5 test --config base44/tests/rewarded-generation/deno.json --no-lock --allow-env --deny-net base44/tests/rewarded-generation/integration_test.ts
```

The verifier mirrors Google's documented once-decoded, ordered query-string signature input and converts canonical DER ECDSA signatures to WebCrypto's P1363 representation. The copy in Supabase must stay byte-identical.

## Unity release candidate (prepared 11 November 2026)

The same authenticated `status` / `prepare` / `claim_status` flow supports Unity
without trusting a device's ad-completed callback. `prepare` returns
`provider: "unity"`, `unity_game_id`, SDK placement `ad_unit_id`, and `server_id`
(the exact opaque `custom_data`). The iOS client sends `server_id` as Unity's
server ID for that viewing. The ledger internally records
`unity:<game_id>:<placement_id>` so an AdMob event cannot satisfy a Unity attempt.

Server settings, on both authoritative backends and the public callback gateway:

- `SPYCLASH_REWARDED_AD_PROVIDER=unity`
- `UNITY_ADS_GAME_ID=800429660`
- `UNITY_ADS_REWARDED_PLACEMENT_ID=BP_Rewarded_iOS`
- `UNITY_ADS_S2S_SECRET`: **the secret issued by Unity Ads Support**, never a
  generated placeholder, app resource or client value.
- `SPYCLASH_REWARDED_GENERATION_ENABLED=true` only for the separately approved
  public activation. Until then it stays false; preparing code changes no users.

Ask Unity Ads Support to enable S2S redeem callbacks for Game ID `800429660` with
this exact base URL (the three static query parameters must be signed too):

```
https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv?provider=unity&game_id=800429660&placement_id=BP_Rewarded_iOS
```

Unity adds `sid`, `oid` and `hmac`. The verifier checks HMAC-MD5 using Node's crypto
implementation as required by Unity's protocol; all decoded parameters are signed
in alphabetical order. It rejects duplicates, unexpected fields, ambiguous
separators, wrong project/placement, unknown SID and missing server configuration.
The callback gateway routes the signed `native`/`legacy` namespace to its existing
authoritative ledger, which independently verifies the signature again. Success
is acknowledged with HTTP 200 and body `1` only after the persisted grant.

Unity's callback carries no signed event timestamp. A new grant therefore needs
its first valid delivery within the attempt's 24-hour window. A repeat of the exact
already-committed offer is acknowledged without a second credit even after that
window. Callback arrival after disabling new offers still settles issued attempts
while the verification configuration is retained. Deleted accounts/attempts cannot
be recreated by a callback. Never log SID, callback signatures or the secret.

**External activation is still required.** Unity's official documentation states
that S2S callbacks are unavailable by default and Support must enable the callback
and provide its secret. Local signed fixtures establish implementation behavior;
they are not evidence that Unity has enabled or delivered callbacks for this app.
The native/public route and the legacy/Base44 route both require a real completed
viewing and an earned-and-spent generation before release acceptance. This work
has not sent a support request, changed dashboard/server settings or deployed.

Source: [Unity S2S redeem callback protocol](https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks).

## Compatible account enrollment

Public rollout additionally requires the server-only `GenerationRewardEnrollment`
entity and native `generation_reward_enrollments` migration. Install the schema
before code that references it, including deletion cleanup, with the global flag
still false. Unenrolled accounts retain the existing policy, so an older public
build with ads disabled is not unexpectedly reduced to three generations.

A supported client sends `supported_reward_provider: "unity"` and integer
`client_build: 228` (or later) with its authenticated `status` action. The server
persists enrollment only when the global rollout is enabled and the selected
Unity project/placement/callback secret are configured. Client IDs, email, body
`user_id`, missing fields, string build values and older build numbers cannot
select a different account or enroll an unsupported client. The legacy Supabase
proxy forwards these fields only after proving the Base44 account mapping.

Enrollment is idempotent and sticky. Every generation reads the stored account
policy inside the same quota/writer lock as reservation; removing or downgrading
the capability afterward does not restore legacy access. Confirmed LIMITLESS
still bypasses the quota. Account deletion clears enrollment and rewards under
the existing lifecycle tombstone, preventing late status/callback writes from
recreating either. The global off switch still restores the prior generation
policy without discarding earned credits.

This is a compatibility rollout, not binary attestation: an account that never
sends a supported status request retains legacy policy. Enrollment begins with
its first successful supported status. Existing usage earlier in the UTC day
counts where it was already tracked by the authoritative backend.
