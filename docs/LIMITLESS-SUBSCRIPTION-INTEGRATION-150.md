# LIMITLESS subscription integration — build 150

## Scope

Version 1.0.2 (150), based on e91325d (build 149). This checkpoint retains the
AI word-count input, accepted-friend resolution, generation retry, Radar overlay,
and notification unread-race corrections already integrated in builds 146–149.
Stripe remains deferred.

## Changes

- Native membership refresh supersedes older in-flight reads after a transaction
  or realtime signal. Superseded callers join the authoritative refresh.
- Access expires at its known server deadline. Missing provider expiry stays
  unknown, and an expired cached active record cannot offer a duplicate purchase.
- Verified transaction delivery coalesces only identical signed payloads in the
  same account generation. Changed renewal/revocation data with the same
  transaction identifier can be delivered again. Failed verification stays
  unfinished; purchase, pending, restore and account-switch state are distinct.
- The Apple verifier reads current subscription status while holding the account
  lease. Delayed refunds cannot overwrite a newer renewal; account token, bundle,
  product, environment, application and subscription-chain identities are checked.
- Signed Apple TEST notifications are acknowledged without changing access.
  Administrator-only request/status diagnostics use the server-held Apple key
  and return a bounded, sanitized delivery status.

## Verification

- Full iOS suite: **529 passed, 0 failed, 0 skipped**.
  Result: `/tmp/SpyClash-150-All-Tests.xcresult`.
- Affected Apple backend suites: **73 passed**; `deno check` passed for
  `app-store-entitlement` and `checkSubscription`.
- Independent native and backend reviews found no concrete remaining defects
  in the changed paths. Release uses StoreKit 2 with no bundled local fixture.
- All 10 pulled production runtime files match the base commit byte-for-byte.
  Prepared deployment changes only `app-store-entitlement`: two existing runtime
  files and two added modules. No entity, secret, rollout flag or Stripe changes.

## External acceptance remains open

This checkpoint has not deployed the revised backend or demonstrated a real
Apple purchase. Full Sandbox purchase/restore requires a connected physical
phone, an authenticated SpyClash account and a Sandbox tester. No connected
physical device or configured Sandbox tester was available during preparation.

Apple server TEST delivery must be requested and checked after the approved
function deployment. The currently configured notification URLs must be checked
through that result, not inferred from an unauthenticated browser GET.

App Store Connect currently has a prepared 1.0.2 draft with build 149; build 150
must replace it after archive validation and upload. The weekly subscription
still needs its real review screenshot and matching review notes, verified review
access, and submission with the app. Public privacy policy and App Privacy must
include linked Purchase History for app functionality. Separate prepared web
privacy artifacts are retained in the release folder.

Archive/upload/portal receipts are maintained outside the source tree. A local
build, passing tests, an upload, review submission and public release are distinct
states; none establishes a successful customer purchase.
