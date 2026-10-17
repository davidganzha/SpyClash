# Apple sign-in and LIMITLESS investigation — build 178

Prepared on 2026-10-17 for the user's confirmed TestFlight **1.0.3 (176)** report. This change is a local preparation checkpoint. No production deployment, signing, Apple upload, tester assignment, purchase, or authenticated billing reconciliation was performed.

Subsequent authorized execution, the recovered Base44 synchronization incident, and current delivery blockers are recorded separately in [the build-178 delivery report](APPLE-LIMITLESS-178-DELIVERY.md). The preparation statements below describe the earlier checkpoint.

## LIMITLESS: runtime contract mismatch

The screenshot's `IAP-BUY-ELIGIBILITY-NONE: ACCESS_UNVERIFIED` is emitted when membership refresh fails, before product loading, purchase preparation, or Apple's purchase sheet. Supabase `app-services` v7 returned four HTTP 502 responses at 17:49:24–17:49:56 UTC, matching the screenshot's 18:49 Europe/London time. The live v7 code hash matches the approved build-176 bridge.

A fresh credential-free, server-side HTTP probe found **200 JSON with only `active`** on all three `checkSubscription` routes: the custom-domain API route, its `/functions/checkSubscription` route, and the canonical `base44.app` API route. A fresh Base44 source pull instead contains the modern handler, which rejects unauthenticated requests with 401 and returns the complete membership contract for verified users. Source and actual public runtime behavior therefore disagree.

The unchanged Supabase bridge rejects an `active`-only response with `legacy_billing_response_invalid` / 502. The candidate tests reproduce this using the actual bridge. This is a concrete explanation consistent with the phone error, but no affected-account response was captured: an authenticated check can reconcile records and was not run. The reason Base44 serves behavior different from its retrieved source is still unresolved.

The [isolated candidate](evidence/full-app/build178/check-subscription-candidate/README.md) packages only `checkSubscription`, using all eight freshly pulled runtime files without changing their bytes. Its manifest and rebuild tool make the exact proposed deployment reviewable. Matching source hashes after deployment will not suffice; the actual endpoint response must be checked. The modern source pull is not a faithful rollback snapshot of the observed old runtime.

## Apple: exact failure remains unresolved

Build 176's generic error comes from the native Apple handoff, before provider registration and the Supabase session exchange. It conflates several callback and terminal-response failures. Existing build-177 diagnostics distinguish those branches, but 177 was never delivered to the phone.

Build 178 retains those bounded `SCA177-…` diagnostic identifiers and makes them usable: a persistent native alert shows the full code and offers Copy support code / OK. Only a typed Apple handoff error can populate it. New attempts, account changes, auth resets and logout clear it; stale completions cannot reopen it. Callback validation and Google transport are unchanged. This is not a confirmed fix for Apple sign-in.

LIMITLESS now retains closed failure categories and a valid HTTP status through purchase preflight, for example `ACCESS_UNVERIFIED/HTTP_502/BILLING_RESPONSE_INVALID`. Arbitrary backend codes, messages, bodies, URLs, and credentials are excluded from the support identifier. Unknown access continues to block purchase.

## Verification

- Selected native auth, ownership, callback and membership tests: **111 passed, 0 failed**.
- Rendered native-alert test: **1 passed**, full support identifier/actions inspected in [Simulator screenshot](evidence/full-app/build178/apple-support-alert.png); persistent after the toast expires. This uses a synthetic failure.
- Google web callback regression: **66 passed, 0 failed**, hosted callback source unchanged.
- Actual candidate handler and unchanged billing bridge: **16 test steps passed**, with network and environment access denied. FREE, active Apple/admin access, expiry, purchase gates, uncertainty, unauthenticated requests and old-response rejection are covered.
- Candidate runtime typecheck with actual SDK/Stripe definitions, byte-for-byte package verification and reproducible flattening passed.
- Independent Apple and membership diff reviews found no blocking issue.
- Generic-iPhone **SupabaseRelease unsigned archive succeeded**, with app/widget 1.0.3 (178), exact candidate configuration and privacy manifest. Simulator release-bundle gate passed. The archive is not an installable or uploaded IPA.

Evidence is under [build178](evidence/full-app/build178/). Local fixtures and unsigned artifacts do not prove successful real Apple sign-in, a Sandbox purchase/restore, or acceptance on the phone.

## Concrete next actions requiring fresh approval

1. Canonical Base44 app `69a0e57fa939f578082f8091`: deploy only the reviewed `checkSubscription` candidate. Preserve all secrets, rollout flags and other functions. Afterward verify the actual credential-free endpoint returns the expected 401/full error contract. If it still returns an `active`-only 200, investigate Base44 runtime state rather than bypassing verification. Any authenticated server probe needs its intended account and reconciliation scope authorized separately; the user may instead retest LIMITLESS directly in installed 176.
2. Sign/export/upload **main SpyClash `com.spyclash.ios`, 1.0.3 (178), TestFlight Internal Only**, and assign it to existing **LIMITLESS Internal QA** (`47a13858-b43b-44a1-bf3e-285722cec320`). Read-only App Store Connect verification on 2026-10-17 confirmed that this private internal group has exactly David Ganzha and Dima Ianushevych and automatic build access is off. Recheck audience before assignment. No App Store release is part of this action.

On 178, retry Apple sign-in and capture the complete support code plus local time. That evidence selects the actual failing branch for a targeted authentication correction. Test Google returning to the recognized account, and separately test the repaired LIMITLESS access check before any user-confirmed Sandbox purchase.
