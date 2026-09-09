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

The revised backend has been deployed under the user's explicit approval.
The signed 1.0.2 (150) archive passed validation, was uploaded, finished Apple
processing with VALID / APP_STORE_ELIGIBLE, and is selected in the 1.0.2 draft.
Public privacy policy changes were published on both domains and verified in
four languages. App Privacy Purchase History was published for App Functionality,
linked to the user, without tracking; all ten existing data types were preserved.

No real Apple purchase has been demonstrated. Full Sandbox purchase/restore
requires a physical phone and an
authenticated SpyClash account. Development-signed device testing requires a
Sandbox tester; TestFlight uses the sandbox automatically and can exercise basic
purchase/restore without a separately configured Sandbox account. A Sandbox
account is needed for controlled billing-retry and accelerated renewal scenarios.
No connected physical device or configured Sandbox tester was available during
preparation.

Reference: [Apple TestFlight purchase testing](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight).

Apple TEST requests reached the deployed handler in both Sandbox and Production.
They exposed a production runtime incompatibility in the Apple SDK's binary OCSP
body reader, addressed by the scoped server follow-up in checkpoint 151. See
`LIMITLESS-APPLE-RUNTIME-151.md` for the fix and live delivery verification.

The weekly subscription's build 150 review notes are saved and verified. The
product still needs its genuine review screenshot, working review credentials,
and submission with the app. The app-level review notes must be refreshed before
submission. Saved review credentials were rejected in real login attempts; no
credentials were reset and no account was created. App Review submission and
public iOS release have not occurred. Receipts are retained in the release folder.

Archive/upload/portal receipts are maintained outside the source tree. A local
build, passing tests, an upload, review submission and public release are distinct
states; none establishes a successful customer purchase.
