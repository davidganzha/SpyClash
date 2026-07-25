# SpyClash App Store assets

The tracked images were generated from Debug preview fixtures of the canonical
`SpyClash.xcodeproj` on an iPhone 17 Pro Max simulator running iOS 26.5.
They predate the final build-14 release pass and must be recaptured from the
final candidate before upload.

## Product-page screenshots

`Showcase/en-US` is the canonical 6.9-inch presentation set. It contains five
flattened RGB PNG files at `1320 x 2868`; `Showcase/en-US-6.5` is the derived
`1284 x 2778` fallback. Do not upload the older raw `Screenshots/en-US`, ZIP,
contact-sheet, or source-capture files.

The current sequence is home, online play, secret role, word packs, and the
Community operative directory. A final recapture should also add a private
online lobby/QR screen and a local pass-and-play or profile/history screen.

The showcase generator flattens every final PNG to RGB and intentionally omits
the four decorative outer corner markers. Run
`python3 scripts/build_app_store_showcase.py` after replacing the source
captures. Validate every output for dimensions, alpha, locale, current UI, and
personal data before upload.

The screenshots use the app's Debug-only preview fixtures. Those fixtures
render the real production SwiftUI screens and bundled assets without creating
fake production accounts or changing production data.

## Capture state

- prepared locale: English (U.S.); Russian and Spanish sets are still required
  unless App Store localization fallback is accepted intentionally
- status bar: 09:41, full signal/Wi-Fi, charged battery
- screenshots contain no real user credentials or production personal data
- no screenshots have been uploaded to App Store Connect
- Every feature is available without a paid tier; no purchase-review image is
  part of this package
