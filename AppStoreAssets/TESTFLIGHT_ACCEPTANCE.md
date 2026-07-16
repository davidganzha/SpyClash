# SpyClash TestFlight acceptance — version 1.0 build 3

Run this gate only after build `1.0 (3)` is processed in App Store Connect and
all 16 Base44 functions are deployed. TestFlight builds use Apple's sandbox
for In-App Purchase, so no real charge is made. Use a dedicated physical
iPhone and a Sandbox Apple Account when sandbox controls or purchase-history
reset are required.

Authoritative Apple references:

- [Testing In-App Purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
- [Testing subscriptions and In-App Purchases in TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/)
- [Request a Test Notification](https://developer.apple.com/documentation/appstoreserverapi/request-a-test-notification)
- [Responding to App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications/responding-to-app-store-server-notifications)

## Test identities and evidence

- Use one fresh SpyClash account for the Apple purchase and one separate account
  for friend, invite, and multiplayer delivery tests.
- Keep passwords, OTPs, Apple credentials, transaction identifiers, and raw push
  tokens out of Git, screenshots, and issue trackers.
- Record device model, iOS version, TestFlight build, test time, and the visible
  pass/fail result for every section below.
- A failure is not waived by a later successful retry. Preserve the first error
  message and relevant anonymous server audit identifier before retrying.

## 1. Deployment preflight

- [ ] `npx base44 functions list` reports exactly the 16 reviewed functions,
  including `app-store-entitlement`, `pushNotificationAction`, and
  `stripe-entitlement-webhook`.
- [ ] A clean app launch produces no backend-function `404` for push-device or
  Live Activity token registration.
- [ ] App Store Connect shows build `1.0 (3)` as processed and the weekly product
  `com.spyclash.app.limitless.weekly` with the real localized `$2.99` price.
- [ ] The build was installed from TestFlight, not Xcode or the local StoreKit
  configuration.

## 2. App Store Server Notifications V2

Run both environments independently after their V2 URLs are saved in App Store
Connect.

- [ ] Request a sandbox `TEST` notification and retain its opaque
  `testNotificationToken` outside Git.
- [ ] Poll the sandbox test-notification status until Apple reports delivery.
- [ ] Confirm the backend accepted the signed V2 payload and returned an Apple
  success status without logging the raw `signedPayload`.
- [ ] Repeat the request and status check against the production endpoint.
- [ ] Confirm a bad signature, wrong bundle, wrong environment, or replayed
  transaction cannot grant LIMITLESS.

Apple sends sandbox notifications once when delivery fails; production V2
notifications have the documented retry schedule. The server must still
reconcile canonical subscription status instead of trusting notification order.

## 3. New Apple purchase

- [ ] Sign in to the fresh SpyClash account and open LIMITLESS from the command
  menu.
- [ ] Confirm the screen shows Apple's real localized weekly price, purchase
  action, Restore Purchases, Terms, and Privacy links.
- [ ] Complete the sandbox purchase for
  `com.spyclash.app.limitless.weekly`.
- [ ] Confirm StoreKit verification finishes and LIMITLESS becomes active without
  restarting the app.
- [ ] Confirm the profile badge and at least one gated capability become active.
- [ ] Relaunch the app and confirm the same entitlement is restored from the
  backend and StoreKit transaction state.
- [ ] Confirm the backend entitlement is bound to the signed-in SpyClash user and
  never exposes raw transaction data to the client.

## 4. Restore Purchases

- [ ] Sign out of SpyClash, reinstall build `1.0 (3)` from TestFlight, and sign
  back in to the same SpyClash account while using the same Sandbox Apple
  Account purchase history.
- [ ] Tap Restore Purchases.
- [ ] Confirm the restore succeeds, LIMITLESS becomes active, and repeated taps
  remain idempotent.
- [ ] Sign in to a different SpyClash account and confirm the original Apple
  purchase cannot silently bind to that live account.

## 5. Stripe and Apple entitlement synchronization

- [ ] With an active Stripe web subscription, sign in to the same SpyClash
  account on iOS and confirm LIMITLESS is active without presenting an external
  checkout link in the iOS app.
- [ ] With an active Apple subscription, sign in to the same SpyClash account on
  the web client and confirm LIMITLESS is active without creating a Stripe
  subscription.
- [ ] Confirm two active providers resolve to one LIMITLESS membership view while
  retaining their independent provider records and expirations.
- [ ] Confirm expiration, refund, dispute, and billing-retry states fail closed
  according to the reviewed backend rules and cannot be overwritten by an older
  event.

## 6. Ordinary push notifications

Test with the recipient app backgrounded and then terminated.

- [ ] Friend request: exactly one notification, correct deep link, no private
  email or game secret.
- [ ] Room invitation: exactly one notification, correct waiting-room context,
  and no notification after the invitation is no longer pending.
- [ ] Game started: delivery to the participating offline player and no delivery
  to unrelated users.
- [ ] Game finished: updates/collapses the match notification as designed.
- [ ] Per-family notification opt-outs are honored without unregistering other
  notification families.
- [ ] Repeated/retried outbox processing does not produce duplicate visible
  notifications.

## 7. Live Activity and Lock Screen privacy

- [ ] Starting an online match creates one Live Activity for the current match
  generation.
- [ ] The Lock Screen/Dynamic Island shows the player ring, current speaker,
  asked/answering player, round, and timer from current server state.
- [ ] A detective's role and word appear only after that participant has viewed
  the private role card.
- [ ] A spy sees the spy role but never receives the secret word.
- [ ] A spectator or differently cased user identity receives no participant
  secret data.
- [ ] Round, speaker, timer, and answer state update while the app is backgrounded.
- [ ] Finishing or abandoning the match ends the Live Activity; a stale activity
  token cannot update a later match generation.

## 8. Subscription review screenshot

- [ ] Capture the LIMITLESS screen from the TestFlight build after StoreKit loads
  the real localized App Store product.
- [ ] The image visibly contains the weekly price and Restore Purchases control,
  but no Apple Account, Sandbox credential, OTP, or personal notification.
- [ ] Replace the local StoreKit reference image only after the capture is
  reviewed. Upload that real capture as the subscription review screenshot.

## 9. Exit criteria

Acceptance passes only when every checkbox above has direct evidence, no
backend-function `404` remains, and a clean TestFlight reinstall reproduces the
purchase/restore/push/Live Activity results. App Review submission remains a
separate explicitly authorized action.
