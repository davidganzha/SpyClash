# LIMITLESS Apple notification runtime — checkpoint 151

## Problem and fix

Real Apple TEST notifications reached `app-store-entitlement` in both Sandbox and
Production but received HTTP 500. Verification diagnostics identified
`response.buffer()` inside Apple Server Library 3.1.0's OCSP validation: the
Base44 deployment runtime (Deno 1.40.2) returned a Web Response without that
node-fetch method.

The compatibility adapter adds a non-enumerable `buffer()` only when absent from
the native Response or node-fetch Response prototype. It returns the original
binary `arrayBuffer()` bytes as a Node Buffer. Existing and inherited methods are
preserved. Unsupported prototypes and body read errors fail closed. Apple SDK
certificate-chain validation, online OCSP checks and JWS verification remain
enabled and unchanged.

Administrator-only TEST status diagnostics now verify Apple's signed TEST
payload server-side and expose a bounded status vocabulary. They do not return
the signed payload, raw nested errors, stacks or keys.

## Verification and deployment

- Affected entitlement and subscription suites: **84 passed**. Type checking and
  `git diff --check` passed; independent adapter review found no concrete defect.
- Deployed only `app-store-entitlement` to canonical app
  `69a0e57fa939f578082f8091` within the user's approved handler publication.
  All **14 reachable runtime files** matched local source after pull-back.
- Both previously failing Apple TEST payloads now pass complete verification
  with `valid=true`, `status=OK` in the deployed runtime.
- Fresh Sandbox and Production TEST notifications each delivered successfully
  on their first attempt (`sendAttemptResult=SUCCESS`), with signature
  verification `valid=true`, `status=OK`. Verified at 2026-09-08 23:51 UTC.
- No schema, secrets, rollout flags, notification URLs or Stripe changes.

## Release boundary

This server follow-up increments the repository checkpoint to 1.0.2 (151).
The uploaded and selected iOS binary remains **1.0.2 (150)** from `410306e`;
native code did not change in this checkpoint. No build 151 has been uploaded.

Apple TEST verification does not prove a customer purchase, renewal or restore.
Real Sandbox purchase/restore, a genuine subscription review screenshot and
working app review access remain open. App Review submission and public iOS
release have not occurred.

Sanitized deployment and live test receipts are retained outside Git under
`/Users/davidganzha/Documents/SpyClash-Releases/1.0.2-150/backend-postflight/`.
