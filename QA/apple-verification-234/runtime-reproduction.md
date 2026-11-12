# Apple verification runtime reproduction

A local reproduction confirms that the pinned Apple App Store Server Library 3.1.0 cannot validate transaction JWS in the unmodified Supabase Edge Runtime 1.70.5 used for this check. The runtime fails before certificate-chain validation at `X509Certificate.toString()`. Apple wraps the runtime exception as `VerificationStatus.VERIFICATION_FAILURE` (numeric 1). SpyClash's native verifier maps that status to `invalid_apple_transaction`, HTTP 422.

This is a runtime compatibility reproduction, not a completed Apple purchase. The screenshot's precise server exception was not logged by the deployed handler; incident correlation is documented separately. No production deployment, account change, entitlement grant, charge, or purchase was performed for this check.

## Runtime and result

- Image: `public.ecr.aws/supabase/edge-runtime:v1.70.5`
- Image digest: `sha256:941e21883ad961ce52da5caba666456a6f61f72c5131b3d22be7cfc2cec5d325`
- Reported runtime: `supabase-edge-runtime-1.70.5 (compatible with Deno v2.1.4)`
- Apple library: `npm:@apple/app-store-server-library@3.1.0`
- Result: [unpatched-edge-runtime.json](unpatched-edge-runtime.json)
- `X509Certificate.toString`, `raw`, `verify`, and `infoAccess` throw `ERR_NOT_IMPLEMENTED`; `ca` works.
- `SignedDataVerifier.verifyAndDecodeTransaction` reports status 1 with cause `Not implemented: crypto.X509Certificate.prototype.toString`.

## Fixture and method

The probe uses the real public Apple root/intermediate/signing certificates bundled in Apple's MIT-licensed v3.1.0 verifier tests. The header contains these parseable certificates; the payload uses the SpyClash bundle and Sandbox environment; the signature is deliberately invalid. This proves where the runtime fails before it can reject the invalid signature. It does not assert that this synthetic JWS is valid or that a purchase has succeeded.

The reproduction files are under `.local/apple-edge-probe/` and contain no private credentials. They are intentionally excluded from the production function. Additional complete JWS fixtures from Apple's test suite use a test CA and are restricted to local regression tests. The production verifier must continue to trust only its configured Apple root certificates.

Commands from the worktree root:

```sh
docker --host unix:///Users/davidganzha/.colima/spyclash-supabase/docker.sock run --rm --name spyclash-apple-edge-probe -v "$PWD/.local/apple-edge-probe:/probe:ro" -p 127.0.0.1:59001:9000 public.ecr.aws/supabase/edge-runtime:v1.70.5 start --main-service /probe
curl -fsS http://127.0.0.1:59001
```

## Owning sources

- [Apple v3.1.0 verifier](https://github.com/apple/app-store-server-library-node/blob/v3.1.0/jws_verification.ts): transaction identity checks at lines 83–91; chain-cache call to `toString()` at line 237; nested runtime exceptions wrapped as status 1 at lines 227–234.
- [Apple v3.1.0 certificate fixtures](https://github.com/apple/app-store-server-library-node/blob/v3.1.0/tests/unit-tests/jws_verification.test.ts).
- [Supabase runtime Node X509 implementation](https://github.com/supabase/edge-runtime/blob/main/ext/node/polyfills/internal/crypto/x509.ts): methods above remain stubs in the inspected upstream source. The pinned Docker result above is the reproducible runtime evidence.

The Production-before-Sandbox loop itself is not the cause established here. Apple checks only bundle and environment for transaction JWS; it checks numeric appAppleId in other payload types. A verified transaction for the correct bundle in Sandbox reaches `INVALID_ENVIRONMENT` when evaluated by a Production verifier, which SpyClash already handles by trying its explicitly enabled Sandbox target.

## Adapter feasibility check

A separate local probe (`.local/apple-cjs-adapter-probe`) confirms that updating the runtime's CommonJS `crypto` export before importing Apple's library makes the SDK construct compatible X509 objects. Restored certificate methods pass. The runtime additionally reports EC curve `p256`, where Node consumers expect `prime256v1`; after normalizing that exact equivalent metadata value, the same fake JWS reaches the expected ES256 signature-length rejection (one byte supplied, 64 required).

This run uses Apple's real certificate chain with online checks enabled. Since the failure occurs in JWS signature validation after certificate validation, the real chain and OCSP checks completed in this probe. The result is [adapter-feasibility-edge-runtime.json](adapter-feasibility-edge-runtime.json). This is an intermediate feasibility implementation; final adapter and complete signed-fixture regression results must be checked separately.
