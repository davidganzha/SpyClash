# Generation rewards

Prepared integration; no environment has been deployed or activated by these changes.

`SPYCLASH_REWARDED_GENERATION_ENABLED=true` activates three free generations per UTC day and separate non-expiring reward credits. Actual verified Apple/Stripe/admin LIMITLESS access stays unlimited. The flag does not change unrelated CASADA benefits. The default is disabled and preserves existing generation access.

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
