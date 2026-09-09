# LIMITLESS weekly period — checkpoint 153

## Problem and fix

The physical-device paywall in diagnostic build 152 reported
`unsupportedProduct`, proving that Apple's catalog returned a product that the
native contract rejected. App Store Connect still identifies
`com.spyclash.ios.limitless.weekly` as `ONE_WEEK`.

The native period check previously accepted only `unit == .week, value == 1`.
It now also accepts the equivalent `unit == .day, value == 7`. Other durations
and missing subscription periods remain invalid. The exact product identifier
and auto-renewable type checks remain required. Displayed prices still come
from the returned StoreKit product.

Bounded catalog diagnostics now include ID/type match booleans, a closed period
unit enum and the numeric period value. No product IDs, prices, account data or
transaction payloads are logged.

## Validation

- **46 tests passed**, zero failed or skipped: 12 catalog and 34 membership.
- The added duration matrix accepts one week and seven days, and rejects missing
  values, other day/week counts, months and years.
- Physical-device Debug build compiled successfully. App and widget signatures
  verified with the existing login-keychain development certificate and existing
  SpyClash profiles. No certificate/profile creation or PotuzhnoSigning use.
- Installed metadata confirms **1.0.2 (153)**; launch succeeded on the phone.
  Live catalog diagnostics and user confirmation of the price are pending.
- Independent code review and `git diff --check` passed.

## Release boundary

153 is installed locally for diagnosis. TestFlight and the selected App Store
Connect binary remain **1.0.2 (150)**; 153 was not uploaded or submitted.
Sandbox purchase, canonical entitlement activation and restore still require
real-device verification.

Sanitized receipts are outside Git in
`/Users/davidganzha/Documents/SpyClash-Releases/1.0.2-153/`.
