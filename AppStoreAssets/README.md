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

The screenshots use the app's Debug-only preview fixtures. Those fixtures
render the real production SwiftUI screens and bundled assets without creating
fake production accounts or changing production data.

## Capture state

- locale: English (U.S.)
- status bar: 09:41, full signal/Wi-Fi, charged battery
- screenshots contain no real user credentials or production personal data
- no screenshots have been uploaded to App Store Connect
- Every feature is available without a paid tier; no purchase-review image is
  part of this package
