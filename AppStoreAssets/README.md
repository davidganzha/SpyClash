# SpyClash App Store assets

Generated from the current Debug build of the canonical `SpyClash.xcodeproj`
on an iPhone 17 Pro Max simulator running iOS 26.5.

## Product-page screenshots

`Screenshots/en-US` contains five portrait PNG files in the intended order.
Every file is `1284 x 2778`, one of the dimensions accepted by the 6.5-inch
iPhone media slot in App Store Connect.

The current sequence is online play, local results, word packs, home, and the
Community operative directory (`05-community.png`).

All prepared PNG files are flattened RGB images without transparency. Run
`swift scripts/flatten-app-store-screenshots.swift` after replacing or
recapturing an image to restore this upload-safe format.

The five product-page screenshots were uploaded to App Store Connect for iOS
version 1.0 on July 16, 2026. Keep this directory as the reviewable source set
for any replacement upload.

The screenshots use the app's Debug-only preview fixtures. Those fixtures
render the real production SwiftUI screens and bundled assets without creating
fake production accounts or changing production data.

## Subscription review screenshot

`SubscriptionReview/limitless-weekly-test-2.99.png` shows the StoreKit purchase
surface and restore control. The displayed `$2.99 / 7 DAYS` value comes from the
local StoreKit test configuration and now matches the saved App Store Connect
weekly base price of USD 2.99. This file is a visual reference only and must not
be attached to App Review. Recapture the same screen from Sandbox or TestFlight
after StoreKit loads the real localized App Store price.

## Capture state

- locale: English (U.S.)
- status bar: 09:41, full signal/Wi-Fi, charged battery
- screenshots contain no real user credentials or production personal data
- all five product-page screenshots have been uploaded to App Store Connect
- the subscription image is intentionally blocked from upload until a
  Sandbox/TestFlight recapture replaces it
