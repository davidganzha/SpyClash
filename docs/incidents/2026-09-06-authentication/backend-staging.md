# Google sign-in recovery: reviewed backend candidate

Prepared on 2026-09-06 for the existing SpyClash app `69a0e57fa939f578082f8091`. Preparation did not deploy functions, invoke application endpoints, or change production configuration.

## Exact scope

| Function | Existing runtime files | Candidate runtime files | Runtime changes |
| --- | ---: | ---: | --- |
| `appleAuthBroker` | 11 | 12 | Modify `entry.ts`; add `google-state-recovery.ts` |
| `googleAuthCallback` | 3 | 3 | Modify `main.ts` |
| Total | 14 | 15 | Exactly 3 files |

Both function configurations retain their existing values. The broker's pulled entry path is flattened from `base44/functions/appleAuthBroker/entry.ts` to `entry.ts`; this is the only configuration normalization. The callback entry stays `main.ts`. The callback's already-deployed `headers_test.ts` is preserved byte-for-byte alongside `headers.ts`; this candidate does not remove previously deployed files. New test files are kept outside the deployment directory.

The broker returns a localized recovery page for browser GET requests explicitly accepting HTML after Google state rejection. The page offers separate, fixed fresh-login destinations for the app and website. It does not continue or redirect using the rejected state. Real JOSE expiry errors are distinguished from invalid signatures in telemetry. JSON callers retain HTTP 400 and the existing `invalid_state` payload. The callback proxy preserves incoming Accept and Accept-Language headers. State/nonce/signature/cookie validation, state lifetime, token exchange, and Apple credential behavior remain unchanged.

There are no entity, secret, authentication configuration, website, automation, or other function changes in this candidate.

## Evidence and artifacts

- CLI authentication was checked successfully before the read-only pulls.
- Only `appleAuthBroker` and `googleAuthCallback` were freshly pulled into an isolated directory. Their complete runtime inventories, bytes and normalized function configurations match the preceding `spyclash-approved-144-kqsvmp8q/postflight` snapshot. Both entry files also match the repository's pre-patch HEAD baseline.
- `backend-runtime.patch` contains the exact three-file runtime patch; `backend-runtime-manifest.json` records its SHA-256 and every baseline/candidate runtime hash.
- `backend-verify-runtime.py` validates the app binding, project configuration bytes, exact two-function inventory, function configurations and every runtime file. It accepts either the flattened staging layout or the CLI's nested entry layout. It rejects additional resources and symbolic links.
- The candidate passes Deno checks for both deployed entry points. An isolated verification copy with the broker entry renamed to `main.ts` solely for the existing test imports passes 65 tests, 0 failures. That copy contains the tests; the deployment directory does not contain new tests.
- Applying the persisted patch to a separate copy of the flattened baseline recreates the exact candidate hashes. Six negative guard checks reject an extra function, an extra Base44 resource, changed function configuration, changed runtime bytes, a wrong app binding and a symbolic link.

Local preparation root:

```text
/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-auth-recovery-145-ftr5b40z
```

It contains `fresh` (unaltered CLI pull), `baseline` (flattened deployed source), `deploy` (reviewed candidate), `verification` (test copy), `patch-reconstruction` (verified patch application), and `isolated-tests.log`. Temporary paths may be removed by macOS; the persisted patch and manifest remain the reviewable record.

## Required preflight and deployment boundary

1. Obtain explicit approval in the current chat for this app and the exact operation `functions deploy appleAuthBroker googleAuthCallback`. A local test pass or checkpoint is not deployment approval.
2. Before deployment, check CLI authentication and freshly pull only these two functions into a new isolated project containing copies of the reviewed `base44/config.jsonc` and `base44/.app.jsonc`. Do not pull into the candidate or repository tree.
3. Run `python3 backend-verify-runtime.py <fresh-root> --mode baseline` from this document's directory. Stop if any runtime/configuration drift is reported. Do not overwrite newer production code with this baseline.
4. Run `python3 backend-verify-runtime.py <candidate-root> --mode candidate`. Use the verified `deploy` directory, which contains only the two functions. If reconstructing it, flatten the baseline according to its function entries, normalize only those entry paths, apply `backend-runtime.patch` with `patch -p1`, and run the candidate guard again.
5. Only after the preceding approval and successful guards, run the exact targeted CLI operation from the verified candidate root: `npx --no-install base44 functions deploy appleAuthBroker googleAuthCallback`. Do not use the general resource deploy or `--force`.
6. Pull the two functions again into a separate postflight directory and run the candidate guard. Retain the deployment result and compare the other functions separately if an all-function snapshot is collected. Structural verification does not prove a fresh Google login on an actual client; that remains a separate UI check.

No production deployment was performed while preparing this package.
