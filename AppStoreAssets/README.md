# SpyClash App Store assets

The current `Build-87` images were captured from the real SwiftUI shell of
`SpyClash` 1.0 (87) on an iPhone 17 Pro Max simulator running iOS 26.5.

## Product-page screenshots

`Build-87/en-US`, `Build-87/ru`, and `Build-87/es-ES` are the current localized
6.9-inch source sets. Each contains seven flattened RGB PNG files at
`1320 x 2868` without alpha. Do not upload the older Build-15/21/22/23/24/28,
`Screenshots`, `Showcase`, ZIP, contact-sheet, source-with-alpha, or duplicate
6.5-inch files as the Build-87 set. Historical Showcase images and ZIPs are
reference material only and include stale content that is not release-ready.

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
- validation: 21/21 files are `1320 x 2868`, RGB, and have no alpha channel
- visual review: 21/21 screens show the intended fixture and locale
- visible release label: `1.87v` on every header-bearing screenshot
- preview online room code: current six-character fixture `R7VN87`
- status bar: 09:41, full signal/Wi-Fi, charged battery
- screenshots contain no real user credentials or production personal data
- no Build-87 screenshots have been uploaded to App Store Connect
- Every feature is available without a paid tier; no purchase-review image is
  part of this package
