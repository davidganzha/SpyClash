# Production deployment — reliability 146

The user freshly confirmed the exact reviewed production scope in this chat.
The root agent deployed to canonical SpyClash Base44 app
`69a0e57fa939f578082f8091`, from the artifacts of source commit
`3e06164b64e94b5849e8974e681cae5a0b82bab4`, iOS `1.0.1 (146)`.
This record documents that deployment; it does not expand the approved scope.

## Deployment and preservation

- The earlier temporary artifact directory had expired. The committed patch
  and manifests reconstructed the identical candidate against a fresh,
  authenticated production pull. No repository code changed during restoration.
  The reconstructed candidate again passed 956 tests and 13 handler steps,
  nine profile fault tests and fifteen negative guards, with zero failures.
- Both initial and immediately pre-publication baselines matched the reviewed
  inventory: 17 functions, 190 files and 25 entity schemas.
- `entities push` exited zero. Its authoritative full-set synchronization
  reported one created entity and 25 updated entities; canonical schema hashes
  proved all 25 existing definitions unchanged. Only `AiWordPackOperation` was
  added. All four access policies for that entity remain admin-only.
- The exact twelve-function deploy started at **16:44:39 UTC** and its successful
  completion was confirmed at **16:46:33 UTC**, on **2026-09-06**. CLI exit status
  was zero and it reported all twelve functions deployed.
- A fresh postflight fetch completed at **16:46:48 UTC**. All 26 schemas matched
  the reviewed candidate. The five unselected functions remained byte-identical.
  All seventeen function configurations matched after entry representation
  normalization, including the existing push retry automation.

Deployed functions:

```text
appleAuthBroker
autoRegisterUser
checkSubscription
communityAction
createCheckout
deleteAccount
gameRoomAction
generateWordPack
googleAuthCallback
pushNotificationAction
stripe-entitlement-webhook
wordPackAction
```

No website, authentication settings, secrets, payment transactions, TestFlight
or App Store state was changed by these operations.

## Explicit postflight representation difference

The committed exact-path function guard stopped at `googleAuthCallback` because
the readback names its entry `entry.ts`, while the reviewed artifact names it
`main.ts`. The same readback omits the historical `headers_test.ts`. Therefore
the original guard is **not** reported as passing and its manifest/implementation
were not changed to hide the difference.

Two independent whole-inventory comparisons confirmed:

- Google `entry.ts` is byte-for-byte identical to the approved `main.ts`.
  `headers.ts` is also identical. No runtime module imports `headers_test.ts`.
- With only that exact entry alias and the single non-runtime test omission
  accounted for, every deployed file hash matches the reviewed candidate.
  There are no other file-content or configuration differences.
- The actual readback has **169 files across the twelve selected functions**
  and **192 files across all seventeen functions**. The original prepared
  artifact had 170 selected files and expected 193 total because it included
  the historical test file.

The actual CLI was Base44 **0.1.0**. Inspection of its installed implementation
showed that it submits paths and bytes without these transformations and writes
the entry/files returned by the API. The difference is therefore an observed
server/API representation; its internal server cause is not established.
No test file was force-published, runtime code modified, or second deploy made
to work around this evidence discrepancy.

## Live verification and acceptance boundary

Public Google protocol checks passed at **16:55:10–16:55:12 UTC**:

- A fresh SSO start reached the Google destination; the probe stopped before
  requesting the provider page. Public JWKS verification passed for the state
  signature, issuer, audience, nonce and fixed callback. Lifetime was 300 seconds.
- Deliberately malformed state requests to both the broker and callback proxy
  returned HTTP 400 with the generic recovery HTML, two fixed fresh-login links,
  cleared transaction cookies and the required cache/referrer/content policies.
  They returned neither raw JSON to the browser nor an automatic redirect.
- The proxy's JSON response retained the existing HTTP 400 `invalid_state`
  contract. The three intentional invalid-state probes explain corresponding
  broker errors during this window; they are not observed user failures.

See [the sanitized protocol receipt](deployment-auth-smoke.json).
No credentials were submitted, Google authorization code exchanged, or completed
account sign-in established by these checks.

Full Google, Apple and email/OTP sign-in and the two-account game matrix remain
open. Build 146 was already installed and launched on Ganzha and the dedicated
iPhone 17 Simulator before this deployment. That provides the clients for
acceptance, not proof of successful authentication or multiplayer behavior.
Optical QR scanning and Radar still require physical-device checks, including
two compatible iPhones for actual peer discovery/ranging.

The lease recovery bound after a hard-killed owner can still reach ten minutes.
Legitimate business conflicts can still return 409. The durable AI journal
protects stable request IDs; an unavailable provider result cannot be inferred
or silently replayed as a new generation. These limits are described in
[the reliability record](README.md).

## Evidence

The temporary deployment evidence directory is:

```text
/var/folders/4j/wkjrm6cn0z9f5v932wqlmfz40000gn/T/spyclash-146-production-wsfvz47q
```

It contains authenticated schema/function acquisition receipts, CLI deployment
logs, reconstruction/test receipts and the independently checked postflight.
Only sanitized structural and protocol receipts are retained beside this report;
no OAuth states, cookies, credentials, authorization codes or account data are
included. Temporary raw artifacts can expire; the committed candidate manifests
and patch remain the source of reviewed byte provenance.

The [structural postflight receipt](deployment-postflight.json) records the
per-function byte/configuration comparison, deployment times, schema preservation
and the explicit Google entry/test exception. The original candidate manifest
and raw-path guard remain unchanged.
