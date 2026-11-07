# FAN result word visibility — 1.0.4 (222)

The all-spies draw result no longer shows the secret word. The no-spies draw shows it in both local and online results. Ordinary result screens retain their word display.

Verified with a signed iPhone 17 / iOS 26.5 Simulator build and the repository signature/Keychain installation checker. All four local/online scenario screens were visually inspected; screenshots are included. The runtime UI snapshot service returned an empty hierarchy during one text wait, so this verification used screenshots, not a passing automated text assertion. No new unit tests were added for this presentation-only change.

No backend changes, production deployment or TestFlight upload.
