# Apple native sign-in investigation — source 177

Prepared on 2026-10-16. Marketing version remains 1.0.3. Source 177 adds bounded native diagnostics; it is **not a confirmed Apple sign-in fix**. No new Base44 or Supabase mutation was performed for this investigation, and upload or distribution of 177 has not been authorized.

## Evidence and localization

The user reported that Apple sign-in still fails after [build 176 delivery](BUILD176-DELIVERY.md). The new screenshot, `IMG_3393.PNG`, shows “Apple sign-in returned an invalid response. Please try again.” at 11:27 Europe/London on 2026-10-16. This is a different observed error from the earlier `invalid_url 400` described in [APPLE-BILLING-176.md](APPLE-BILLING-176.md).

That exact message is emitted by `AppleNativeHandoffError` in the native Apple transport. The handoff must return a Base44 access token before `acceptProviderToken` calls provider registration and the Supabase session bridge. This failure therefore precedes Supabase profile/session mapping. Build 176 maps several distinct failures to the same message, so the screenshot does not identify the exact failed validation or terminal response.

Read-only checks are recorded in [investigation.json](evidence/full-app/build177/investigation.json):

- All **14/14** pulled broker files, including function configuration, match the approved 176 manifest in canonical Base44 app `69a0e57fa939f578082f8091`. There is no evidence of a missing or reverted broker deployment.
- The screenshot time corresponds to 10:27 UTC. Broker logs in that window contain POST 200, GET 302 and GET 200 entries. The logs expose method/status without action or attempt correlation. Their resemblance to a successful bootstrap/token/userinfo sequence is an inference, not a verified trace of the phone attempt or proof of native session completion.
- Credential-free SSO-shape probes reached the broker authorization redirect with the exact new Apple callback retained in state. This supports acceptance of the callback at the initial SSO step. A deliberate negative callback returned JSON 400 with access denial, without `invalid_url`; this does not establish the response shape of a successful real Apple login.
- The phone was unavailable for direct inspection. No successful final provider response or affected-device redirect trace was captured.

## Change in 177

The native handoff now reports fixed support codes for the failed check and, where a response is available, a small structural summary: redirect count, HTTP status, MIME category, endpoint category, query-field flags, provider category and fragment category. Build 176 discarded the final HTTP response and reported `missingCallback` when no authenticated redirect had been captured; 177 makes that branch distinguishable from a rejected callback or intermediate redirect.

The accepted callback origins, paths, schemes, provider checks, duplicate-key rejection, token/error exclusivity, value bounds, inert-fragment allowlist and redirect limit are unchanged. HTML, JSON and response headers never supply an authentication token. Response bodies remain ignored, and diagnostic values contain no raw URL, query names or values, provider credentials, server error text or persistent trace.

Google's native flow and hosted callback are unchanged. Its callback SHA-256 remains `a59964b250227975fe8093ed912a9eec094813d7df5017aa763e2fad14c09f3c`.

## Support-code legend

The displayed form is `[SCA177-Hxx-rN-sNNN-cX-uXX-qHEX-pX-fX]`. The structural suffix is absent when no response diagnostic has been attached.

| Failure code | Meaning |
| --- | --- |
| H01 / H02 | Generic invalid bootstrap / callback fallback |
| H03 / H04 / H05 | Rejected intermediate redirect / more than 12 redirects / HTTP completion without a captured callback |
| H06 / H07 / H08 / H09 | Provider cancellation / expiry / temporary unavailability / rejection |
| H10 / H11 | Invalid bootstrap origin, path or fragment / invalid bootstrap query |
| H20 / H21 / H22 | Rejected callback fragment / origin or path / query value |
| H23 / H24 / H25 / H26 | Wrong or missing provider / invalid token-error combination / missing token fallback / duplicate decoded query name |

| Suffix | Meaning |
| --- | --- |
| `r` | Redirect count, clamped to 0–13 |
| `s` | HTTP status 100–599, or 0 when unavailable/out of range |
| `c` | Content category: H HTML, J JSON, O other, N absent |
| `u` | Endpoint category: NB native bootstrap, AU broker authorize, BR other broker action, SL SSO login, SC SSO callback, AC Apple HTTPS callback, LC legacy custom-scheme callback, OT other trusted endpoint, UN unknown |
| `q` | Hex bitmask: 01 provider field, 02 token, 04 error, 08 error description, 10 unrelated field, 20 duplicate name, 40 nil/empty value, 80 invalid value |
| `p` | Provider category: A Apple, G Google, O other, N absent |
| `f` | Fragment category: N absent, I allowed inert marker, O other |

On a rejected redirect, `s` describes the redirect response while `u/q/p/f` describe its proposed destination. On completion without a callback, these fields describe the terminal response URL and envelope.

These categories describe structure only. They do not make an unknown endpoint trusted or relax any authentication rule.

## Validation

- Focused native regression ([native-regression.json](evidence/full-app/build177/native-regression.json)): **42/42 passed** — AppleNativeHandoff 12, AppleAuthenticationOwnership 2, AuthenticationFlow 14, WebAuthenticationCoordinator 14. New coverage distinguishes terminal HTML/JSON/error responses, verifies diagnostics exclude synthetic secrets, preserves redirect rejection and checks cancellation ownership.
- Google web regression: **66/66 passed**, callback source unchanged; see [google-regression.json](evidence/full-app/build177/google-regression.json).
- Unsigned generic-iPhone **SupabaseRelease archive succeeded**, version 1.0.3 (177). Main bundle, widget version, exact candidate configuration, privacy manifest and separate Apple/Google callback routes passed checks; see [unsigned-archive.json](evidence/full-app/build177/unsigned-archive.json). The archive is not signed, installable or uploaded to TestFlight.

Independent privacy/policy review passed: all acceptance guards match 176 after normalizing only error labels; see [independent-review.json](evidence/full-app/build177/independent-review.json).

These local tests prove diagnostic classification and regression behavior, not successful live Apple sign-in. The precise real-device failure and its correction remain unresolved.

## Next device attempt

After separate approval and verified delivery of main SpyClash 1.0.3 (177) through TestFlight, install it on Ganzha and retry Apple sign-in. If it fails, capture the entire `SCA177-…` code and the local time; do not share a callback URL, token or credential. If it succeeds, confirm the recognized profile and then repeat Google sign-in as a regression check.

Use the resulting code to identify the failed branch before changing the callback contract or backend. Production deployment, TestFlight distribution and App Store actions remain subject to the repository's exact-authorization rule. No App Store submission is part of this investigation.
