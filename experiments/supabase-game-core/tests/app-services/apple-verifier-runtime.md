# Apple verifier runtime regression

Run from the repository root with Deno 2.x:

```sh
deno test --no-lock --allow-env=APPLE_EMULATE_EDGE_RUNTIME --allow-net=127.0.0.1 experiments/supabase-game-core/tests/app-services/apple-verifier-runtime_test.ts
APPLE_EMULATE_EDGE_RUNTIME=1 deno test --no-lock --allow-env=APPLE_EMULATE_EDGE_RUNTIME --allow-net=127.0.0.1 experiments/supabase-game-core/tests/app-services/apple-verifier-runtime_test.ts
deno test --no-lock experiments/supabase-game-core/tests/app-services/apple-verification-policy_test.ts
```

The runtime suite generates an ephemeral ECDSA certificate authority, Apple-purpose intermediate/leaf certificates, and delegated OCSP responder certificates. All OCSP requests stay on a temporary loopback listener. The unmodified Apple SDK 3.1.0 validates actual signed JWS and DER OCSP responses. Test roots and private keys are never written to disk or used by application configuration.

Twenty cases cover Sandbox and Production transactions, environment selection, wrong bundle, altered payload, untrusted root, expired certificate, missing Apple OID, wrong signing curve, `none`/HS256 algorithm confusion, revoked/unknown/stale/malformed-date/bad-signer/tampered OCSP responses, temporary OCSP failure, safe diagnostics, and App Store API authorization JWT signing. The wrapper also verifies DER/PEM certificate input round-trips and idempotent adapter installation.

The emulated run restores the missing X509 methods and key-curve aliases observed in Supabase Edge runtime 1.70.5. Run it separately so jsonwebtoken imports its key factories after installation. Emulation complements the independent official Edge runtime container check; it does not replace it.

Two policy tests cover the HTTP 503/422 classification in `verifyApple`, diagnostic redaction, and strict UTC parsing including leap years, overflow, malformed strings and repeated parser installation.

Before the date compatibility fix, the signed stale-OCSP case failed because Apple SDK 3.1.0 accepted a response whose timestamp parsed as `Invalid Date`. The case now rejects that response.
