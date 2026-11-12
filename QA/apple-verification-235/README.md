# Follow-up: mixed Apple trust roots (235)

The user retried in TestFlight build 232 after the approved v24 deployment and reported the same `IAP-BUY-SERVER-NONE: HTTP_422` at 12:07 on 2026-11-12. The v24 logs at 12:06:58.722 and 12:07:22.325 UTC report `Production / VERIFICATION_FAILURE / VERIFICATION_REJECTED / runtimeFailure: false`. Publication of v24 succeeded, but it did not resolve the user's purchase.

## Confirmed cause

Read-only configuration digest comparison established that production trusts these public Apple roots in order: AppleIncRootCertificate (RSA), AppleRootCA-G2 (RSA), AppleRootCA-G3 (EC). Their compact JSON/base64 array has SHA-256 `47e18bba161091237e42d517077bf4e40a0b91e6e52f63a836e237c91e32e8ac`, matching the stored setting's digest. The app ID, bundle ID and SandboxAndProduction environment digests also match their expected values. No secrets or settings were modified.

Apple's verifier tries each root until it finds the signer. Native Node X509 returns `false` when an EC-signed intermediate is checked against an RSA public key. The compatibility adapter added in v24 delegated that case to jsrsasign, which throws the primitive string `Signature: unsupported public key alg: ecdsa`. Apple's SDK wraps that non-Error throw in a verification failure without a cause. The first RSA root therefore aborted the search before the correct EC root. The prior regression fixtures used a single EC root and missed this case.

The failure is reproduced using the exact public root order: [native comparison](node-mixed-roots-reproduction.json), [Edge before](edge-three-roots-before.json), [Edge after](edge-three-roots-after.json). After the fix the real Apple chain and both online OCSP checks pass, while the probe's deliberately invalid JWS signature remains rejected. This is not a successful real-user transaction test.

## Repair and deployment scope

The adapter now returns `false` for incompatible certificate-signature/public-key types. Compatible types still require full cryptographic signature verification. No exception catch-all, additional trusted root, ownership change, environment change, or skipped verification is introduced.

The hosted candidate is the exact v24 bundle with **one adapter file changed (eight added lines)**. All 77 files are accounted for in [candidate manifest](candidate-manifest.json); [candidate patch](candidate.patch) is the complete production delta. The source build number is synchronized at 235, with marketing version 1.0.4 unchanged. The iOS purchase implementation is unchanged.

The new regression fixtures place two RSA roots before the trusted EC root, assert that all-wrong roots remain rejected, and verify that a forged payload is still rejected after the correct root is found. The mixed-root success test failed on the previous adapter before this repair.

## Validation

- All 23 signed-verifier cases passed in official Supabase Edge Runtime 1.70.5 with ESZIP packaging and an RSA-first bootstrap: [results and source hashes](edge-eszip-regression-results.json). Both root orders, all-wrong roots and forged payloads are covered.
- The same 23 cases passed in ordinary Deno and simulated Edge runtime. Adapter-only checks also verify incompatible RSA/EC keys, unrelated EC keys/curves and tampered certificate signatures remain rejected.
- The exact public three-root configuration passes the real Apple chain and both online OCSP checks after the repair. Its deliberately invalid payload is still rejected.
- Both the full local server entrypoint and the minimal hosted candidate pass strict Deno type checking. The tracked patch reconstructs all 77 candidate file hashes; only the intended adapter differs from v24. Whitespace validation passes.
- Independent focused review found no actionable security issue. No production deployment or real-user purchase was performed in these tests.

## Authorization and acceptance

This candidate is prepared for a fresh explicit approval to replace `app-services` in Supabase project `bbkfsgnordtdiblgdzkg`. The previous approval covered the already completed v24 deployment. Before another publication, re-read the hosted v24 bundle and compare every file against [baseline](live-baseline.json); rebase if it has changed.

The user's real purchase remains unconfirmed. After an approved publication, TestFlight restoration/reconciliation is still required for acceptance. Local tests do not establish that acceptance.
