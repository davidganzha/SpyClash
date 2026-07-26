# SpyClash App Store assets

The current `Build-22` images were captured from the real SwiftUI shell of
`SpyClash` 1.0 (22) on an iPhone 17 Pro Max simulator running iOS 26.5.

## Product-page screenshots

`Build-22/en-US`, `Build-22/ru`, and `Build-22/es-ES` are the current localized
6.9-inch source sets. Each contains seven flattened RGB PNG files at
`1320 x 2868`. Do not upload the older `Screenshots`, `Showcase`, ZIP,
contact-sheet, or duplicate 6.5-inch files as the build-22 set.

The current sequence is home, private lobby/QR, secret role, active online
round, local pass-and-play, word packs, and Community attention/actions.

Use `scripts/capture-app-store-source-screenshots.sh` to regenerate the source
sets. Validate every output for dimensions, alpha, locale, current UI, and
personal data before upload.

The screenshots use the app's Debug-only preview fixtures. Those fixtures
render the real production SwiftUI screens and bundled assets without creating
fake production accounts or changing production data.

## Capture state

- prepared locales: English (U.S.), Russian, and Spanish (Spain)
- status bar: 09:41, full signal/Wi-Fi, charged battery
- screenshots contain no real user credentials or production personal data
- no screenshots have been uploaded to App Store Connect
- Every feature is available without a paid tier; no purchase-review image is
  part of this package
