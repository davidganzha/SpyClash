# LIMITLESS product loading — checkpoint 152

## Observed problem and change

On TestFlight 1.0.2 (150), the physical-device paywall showed no price and only
Retry. StoreKit's empty catalog response and thrown request errors were not
visible in the paywall, so this symptom did not identify Apple's failure.

Product loading now has separate observable catalog state. Concurrent callers
await the same request, and dismissing a sheet does not discard that shared
request. A later retry can recover from a failed or empty result. Catalog
loading does not change purchase, restore or membership verification state.

The paywall explains an empty response, unsupported product, network error,
unavailable storefront or other StoreKit failure in all four app languages.
The product must still match the exact identifier, auto-renewable type and
one-week period. Prices continue to come exclusively from StoreKit.

Diagnostics record only response count/match or an allowlisted error domain and
numeric code. They exclude error messages, userInfo, URLs, account information
and signed transaction payloads. Debug builds also emit these bounded fields to
the attached device console.

## Validation

- Catalog and membership suites: **43 passed**, zero failed or skipped.
- Device Debug build compiled successfully; independent code review and
  `git diff --check` passed.
- App and widget signatures verified using an existing Apple Development
  certificate in the login keychain, team `3Z64QKNL54`, and existing profiles
  for the two SpyClash bundle IDs. Both profiles include the connected phone.
  No new certificate or profile was created; PotuzhnoSigning was not used for
  the resulting artifact. Repository signing settings remain unchanged.
- Installed metadata on the connected phone confirms **1.0.2 (152)**.
  The initial launch was blocked by the phone's locked screen. After unlocking,
  a live process was verified and the user's screenshot showed
  `unsupportedProduct`: Apple returned a product, but the native contract
  rejected it. This narrowed the investigation to product parameters.

## Release boundary

152 is a local development diagnostic build. TestFlight and the selected App
Store Connect binary remain **1.0.2 (150)**. No 152 upload, App Review submission
or public release occurred.

The original missing-price cause and real Sandbox purchase/restore are still
unverified. A successful compile, signature or installation does not establish
that Apple's product catalog is available or a purchase succeeds.

Sanitized test and device receipts are outside Git in
`/Users/davidganzha/Documents/SpyClash-Releases/1.0.2-152/`.
