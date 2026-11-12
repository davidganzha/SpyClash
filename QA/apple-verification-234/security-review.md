# Independent review of the Apple verifier repair

Scope: `apple-x509-compatibility.ts`, `apple-ocsp-date.ts`, their invocation in `native-apple.ts`, and the actual pinned SDK calls exercised in Supabase Edge Runtime 1.70.5. No actionable security finding remained at this review point. This does not prove a real user purchase or production deployment.

## Preserved verification boundaries

- The native certificate parser still accepts or rejects certificate input. The adapter retains native public keys, validity dates, subject/issuer names and CA constraints. It restores raw/PEM encoding, certificate signature verification and AIA access for methods the edge runtime leaves unimplemented.
- The missing synchronous certificate signature operation uses pinned jsrsasign signature verification. It does not return a fixed success result. Apple's verifier still checks the configured trusted root, intermediate/leaf signatures, issuer names, CA flag, Apple purpose OIDs, dates, OCSP authorization and signatures, certificate IDs, status, and the JWS signature.
- Curve metadata normalization applies only to a known equivalent alias and is cross-checked against the native public JWK's actual curve. It exports no private key material. Algorithm/curve checks remain active; a P-384 key cannot pass an ES256 check.
- The CommonJS crypto replacement is installed before dynamically importing Apple's library. This covers both the transaction chain and OCSP signer certificates constructed inside that library. The observed runtime shares the CommonJS and default crypto export objects. Other local app-services use of node crypto is HMAC/timing-safe equality, whose exports are unchanged.
- The adapter is capability-gated and idempotent. A runtime with complete X509 support keeps its native constructor. It accepts DER and PEM bytes/string forms and returns a copy of stored DER. AIA control characters are rejected.
- `apple-ocsp-date.ts` restores strict UTC parsing for the pinned SDK's OCSP timestamp method on each verifier instance. It rejects invalid dates instead of allowing `Invalid Date` to disable freshness comparisons. The SDK's normal clock skew and all signature/status checks remain in force.
- App bundle/product/environment gates and purchase/account ownership checks remain in the owning application logic. A recognized missing server crypto primitive becomes a retryable server error; an invalid signature remains rejected. Diagnostics use a closed vocabulary and do not log transaction payloads or credentials.

## Local verification

[edge-regression-results.json](edge-regression-results.json) records the complete signed-fixture suite using real generated certificate chains, JWS signatures and DER OCSP responses. Certificates and private keys are disposable in-memory test fixtures. They are never accepted by the production configuration.

A separately hashed final X509 adapter check is in [final-x509-adapter-edge-runtime.json](final-x509-adapter-edge-runtime.json). It verifies Apple's upstream signed transaction/renewal fixtures with their test CA, rejects a tampered payload, and proves the adapter accepts PEM buffers. Its real Apple chain probe proceeds to the expected invalid signature rejection. The complete signed-fixture suite is the evidence for the subsequent OCSP timestamp patch and final security cases.

To rerun the committed harness from the repository root:

```sh
docker --host unix:///Users/davidganzha/.colima/spyclash-supabase/docker.sock run --rm --name spyclash-apple-regression-edge -v "$PWD:/repo:ro" -p 127.0.0.1:59004:9000 public.ecr.aws/supabase/edge-runtime:v1.70.5 start --main-service /repo/QA/apple-verification-234/edge-runtime
curl --max-time 55 -fsS http://127.0.0.1:59004/run
```

The harness binds its host port to loopback and uses only local synthetic identity and OCSP endpoints. It does not call the production app, database or entitlement endpoint.
