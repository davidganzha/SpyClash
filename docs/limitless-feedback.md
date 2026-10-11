# LIMITLESS, reviews, and Radar feedback

The original monthly preparation started at release source `d327b0db` (1.0.2
build 161). Its purchase recovery, review, and Radar improvements are now part
of the combined TestFlight source, together with the separate feedback and
onboarding changes.

## Current TestFlight offer: weekly

For this TestFlight build, the user explicitly selected preserving the existing
weekly subscription. The active client requests
`com.spyclash.ios.limitless.weekly`, validates a one-week or seven-day period,
and displays Apple's localized `Product.displayPrice` with weekly renewal copy
in English, Russian, Spanish, and Ukrainian. The prepared monthly product is
not offered by this build.

Purchase preparation must return exactly the displayed, supported product ID.
A monthly preparation response cannot authorize weekly checkout, and a weekly
response cannot authorize monthly checkout. Both known product IDs remain
supported for verified transaction delivery and restores.

## Dormant monthly price proposal

The earlier proposal was **GBP 3.00 per month**, superseding the screenshot and
the earlier EUR 2.99 clarification. Do not silently substitute GBP 2.99. This
proposal is deferred for the current weekly TestFlight release. A local
StoreKit fixture is not evidence of production price or availability.

The monthly product is prepared locally and is not activated for live sales.
`StoreKit/SpyClash-Monthly.storekit` contains a GBP 3.00/P1M test fixture plus the
legacy weekly product; it does not configure App Store Connect. Activation requires:

1. Verify that App Store Connect offers the exact GBP 3.00 price point for GBR.
   If unavailable, obtain the user's decision before choosing another amount.
2. Create a monthly product in the existing subscription group, with a distinct
   product ID (`com.spyclash.ios.limitless.monthly`). Apple does not
   permit changing a subscription's duration after submission for review.
3. Deploy the prepared server compatibility changes after reconciling the live
   function with this source. Keep `APPLE_IAP_PRODUCT_ID` set to the existing weekly
   ID. Monthly checkout also requires the separate
   `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED=true` flag, which defaults
   to false and does not restrict restoring either product.
4. Separately change the active client product and all period/renewal copy to
   monthly, then verify that the app, Apple product, and server agree on that ID.
   The client sends `requested_product_id`; older clients omit it and retain
   weekly checkout. A returned weekly context cannot authorize a monthly buy.
   Deploying this code alone does not configure or enable the monthly offer.
5. Verify monthly purchase, cancellation, pending approval, restore, renewal,
   and existing weekly subscribers in Apple Sandbox before enabling the offer.

A historical weekly transaction may reconcile to a monthly product in the same
Apple original-transaction chain after a crossgrade. The new client accepts this
only with the explicit verified `submitted_product_id` response. Older binaries
have an exact-product response check and need the app update for this crossgrade
case; unchanged weekly renewals and restores retain their existing contract.

Any future discount must be an actual App Store offer whose eligibility,
duration, discounted price, and renewal price are displayed accurately. No
discount claim or introductory offer is added by this patch.

## Purchase recovery

The primary action now explicitly offers Subscribe when access needs checking;
the existing server eligibility, account scope, product, and purchase-context
checks still run before Apple checkout. Active access retains a separate refresh
action. Closed checkout gates expose a reason and a retry. Purchase failures
produce an alert with a bounded support code. Tap-time intent and account scope
are captured so a queued refresh cannot change a Verify tap into a purchase.

## Radar onboarding

Unsupported Local Network onboarding is omitted, including the upgrade-only
flow. Permission denial on supported devices remains recoverable. UWB is only
needed for precise distance; its absence does not disable peer discovery, and
the related distance promise is omitted on devices without that capability.

## Review action

The Home action opens Apple's review page directly. It does not collect a local
star rating, filter users by their sentiment, or reward App Store reviews.

## Evidence boundaries

Local tests and Simulator previews validate app behavior. They do not prove that
Apple's live product, server checkout flag, or a real purchase works. No backend
deployment, App Store configuration change, or release is included.

## Current weekly adaptation checks

Regression tests cover the selected weekly product, rejection of mismatched
purchase contexts, dormant monthly preparation support, both catalog period
contracts, and weekly renewal language in all four locales. The combined
release build and integrated test results are recorded by the release task.

## Historical monthly preparation validation

The following results belong to the earlier monthly preparation branch and do
not certify the combined weekly TestFlight build:

- Final focused iOS run: 134 passed, 0 failed, 0 skipped. Covers membership and
  purchase preflight, both product contracts, response/crossgrade delivery,
  transaction retries, onboarding routing, and Local Network lifecycle.
- Backend: 74 passed, 0 failed with local Deno; entitlement entry typecheck passed.
- Function bundle isolation, source baseline ancestry, fixture consistency, and
  `git diff --check` passed.
- Fresh 1.0.2 (164) Simulator app installed and launched. Home review footer is
  visible on the landing page and absent in mode selection. LIMITLESS presents
  Subscribe and monthly renewal copy. Preview shows no fabricated live price.
- Home and LIMITLESS screenshots are saved with the chat artifacts outside the
  source tree (not committed).

## Apple references

- [Subscription duration and metadata](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/auto-renewable-subscription-information/)
- [Subscription pricing](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions/)
- [User-initiated review links](https://developer.apple.com/documentation/StoreKit/requesting-app-store-reviews)
- [App Review Guidelines, sections 5.6.1 and 5.6.3](https://developer.apple.com/app-store/review/guidelines/)
