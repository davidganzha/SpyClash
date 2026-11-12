# Mixed Apple trusted roots: independent reproduction

The build234 runtime adapter used jsrsasign `X509.verifySignature()` as the implementation of Node's `X509Certificate.verify()`. These methods differ when the candidate issuer key uses a different algorithm. Apple's SDK tries every configured root; it expects an incompatible candidate key to return `false`, then continues to the matching root.

The configured root list is the public Apple Root CA (RSA), Apple Root CA G2 (RSA), and Apple Root CA G3 (EC), in that order. Its compact JSON SHA256 is `47e18bba161091237e42d517077bf4e40a0b91e6e52f63a836e237c91e32e8ac`. The parent investigation compared this hash with the hosted secret digest; no production secret/configuration was changed.

## Independently observed behavior

Using Apple's real `SHA384withECDSA` signing intermediate and the public three-root list:

- Node22.22.1 returns `false`, `false`, `true` for roots CA, G2, G3 respectively.
- jsrsasign11.1.3 throws the primitive string `Signature: unsupported public key alg: ecdsa` for both RSA roots; it returns `true` for G3.
- Consequently the old adapter aborts Apple's root search at the first RSA root. It never reaches the valid G3 trust path.
- The Apple3.1.0 SDK only retains a nested cause if the thrown value is an `Error`; a thrown string becomes `VERIFICATION_FAILURE` without a cause. This explains why the current sanitized diagnostic reports `VERIFICATION_REJECTED` with `runtimeFailure:false`.

The concrete independent result is [node-mixed-roots-reproduction.json](node-mixed-roots-reproduction.json). It includes public certificate fingerprints and no private keys, user receipts, account identifiers, or credentials. The method-level probe is under `.local/repair235/node-mixed-roots-probe.mjs`.

## Required repair boundary

Return `false` for a proven signature-algorithm / candidate-key-type mismatch before calling jsrsasign. Continue to verify compatible candidates cryptographically. Do not catch every exception and do not return `true` for an incompatible root. All root, issuer, CA flag, Apple-purpose OID, date, revocation, payload signature and account ownership checks must remain active. Keep all three configured roots rather than changing production trust configuration to hide the adapter defect.

The previous signed-fixture suite used one EC root, so it did not cover the deployed mixed RSA/EC root configuration. Regression coverage must include both RSA-before-EC and EC-before-RSA order, RSA-only rejection, malformed certificates, unrelated compatible keys, and preservation of non-mismatch runtime failures.

## Source references

- [Node X509 verification contract](https://nodejs.org/api/crypto.html#x509verifypublickey).
- [jsrsasign X509 verifier](https://kjur.github.io/jsrsasign/api/symbols/X509.html#verifySignature).
- [Apple3.1.0 SDK](https://github.com/apple/app-store-server-library-node/blob/v3.1.0/jws_verification.ts): root iteration at lines261–266, and exception wrapping at lines227–234.

No production writes or purchase attempts were performed for this reproduction.

## Fix review and exact configured-root probe

The prepared adapter checks the parsed certificate signature algorithm and the native candidate issuer key type. Known ECDSA/non-EC and RSA/non-RSA mismatches return `false`. Compatible key types still go through the same `verifySignature()` call; there is no blanket exception catch and no new successful verification path for an incompatible key. This matches Node's mismatch behavior and allows Apple's existing loop to continue through all configured roots. Both RSA-before-EC and EC-before-RSA are covered because the SDK continues iterating after finding a match. No actionable security issue was found in this focused change.

[Before](edge-three-roots-before.json) and [after](edge-three-roots-after.json) use the actual public three-root list, the real Apple intermediate and signing certificate, online OCSP, and an intentionally invalid one-byte JWS signature. Before the patch, verification aborts in certificate chain validation without reaching OCSP. After the patch, certificate validation and both OCSP checks complete, then the SDK correctly rejects the invalid signature length. This demonstrates recovery of the original verification path without treating a fake transaction as valid.

The final signed-fixture suite uses disposable in-memory keys and includes complete valid Sandbox and Production transactions, both root orders, all-wrong mixed roots, and forged signatures. No real customer transaction or charge is created by these local checks.

## Final packaged-runtime validation

All 23 shared signed-verifier scenarios passed in the official Supabase Edge Runtime 1.70.5/Deno2.1.4 after bundling the final harness as ESZIP. The bootstrap uses the first RSA root, matching the deployed configuration's key type. Results and exact source hashes are in [edge-eszip-regression-results.json](edge-eszip-regression-results.json). The valid mixed-root scenario executes both RSA,RSA,EC and EC,RSA,RSA order.

From the worktree root, create a local output directory, then run:

```sh
mkdir -p .local/repair235
docker --host unix:///Users/davidganzha/.colima/spyclash-supabase/docker.sock run --rm -v "$PWD:/repo:ro" -v "$PWD/.local/repair235:/out" public.ecr.aws/supabase/edge-runtime:v1.70.5 bundle --entrypoint /repo/QA/apple-verification-235/edge-runtime/index.ts --output /out/apple-regression-235-final.eszip
docker --host unix:///Users/davidganzha/.colima/spyclash-supabase/docker.sock run --rm -v "$PWD/.local/repair235:/probe:ro" -p 127.0.0.1:59004:9000 public.ecr.aws/supabase/edge-runtime:v1.70.5 start --main-service /probe/apple-regression-235-final.eszip --main-entrypoint file:///repo/QA/apple-verification-235/edge-runtime/index.ts
curl --max-time 55 -fsS http://127.0.0.1:59004/run
```

The test container was stopped and removed after validation. The shared local Supabase database stack was left unchanged.
