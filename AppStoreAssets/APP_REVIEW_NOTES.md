# SpyClash App Review package

Prepared for iOS version 1.0, build 3.

## Secure App Store Connect fields

Do not commit review credentials or private contact details to this repository.
Before submission, App Store Connect still needs:

- a dedicated review account email and password that do not require OTP or MFA;
- review contact first name, last name, international phone number, and a
  monitored email address.

## App Review Notes

Paste the following into the App Review Notes field after adding the secure
review credentials above:

> SpyClash is a social-deduction party game with online rooms, local pass-and-play, Community profiles, friend requests, room invitations, push notifications, and Live Activities.
>
> LIMITLESS subscription: after signing in, pull down the command-menu handle at the top of the app and tap LIMITLESS. Tap the primary LIMITLESS action to open Apple's StoreKit purchase sheet. RESTORE PURCHASES is directly below that action. The iOS app uses only Apple In-App Purchase; it does not present Stripe checkout or an external purchase link. Stripe is used only on the separate web client, and provider entitlements are synchronized to the signed-in SpyClash account by the backend.
>
> Community safety: open the command menu and tap COMMUNITY. Player profiles and comments provide Report and Block controls. Blocking removes the relationship, comments, and invitations between the two accounts and prevents further discovery and contact.
>
> Notifications: the system authorization prompt appears after the first successful sign-in. Notifications cover friend requests, room invitations, and game-state events. A Live Activity starts for an active online match and shows the current round, timer, speaker/turn state, and the signed-in participant's own role or word on supported lock screens.
>
> Account deletion: open the command menu, tap PROFILE, scroll to DANGER ZONE, and choose DELETE ACCOUNT. Deletion removes the SpyClash account and associated app data. Apple subscriptions must still be cancelled through Apple, as explained before confirmation.

## Subscription review screenshot

The checked-in `SubscriptionReview/limitless-weekly-test-2.99.png` is only a
layout reference generated with the local StoreKit configuration. Before the
first subscription submission, replace it with a screenshot captured from
Sandbox or TestFlight that visibly shows the real localized App Store price and
the Restore Purchases control.

## Remaining review-only verification

- Verify the dedicated review account on build 3 using the exact credentials
  entered in App Store Connect.
- Verify a real Sandbox purchase, entitlement restoration, and server sync.
- Capture the subscription review screenshot from that verified build.
- Attach the LIMITLESS subscription to the version 1.0 submission together with
  the app's first review submission.
