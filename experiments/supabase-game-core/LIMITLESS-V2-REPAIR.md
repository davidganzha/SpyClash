# LIMITLESS verified membership route repair

Prepared and deployed 2026-10-17 after the user explicitly approved both listed operations. No TestFlight action was performed. The server routing correction is live; real-account acceptance remains pending.

## Problem and change

The installed Supabase build 176 correctly requests `membership/check`. Its existing bridge verifies the authenticated user's immutable Base44 link and then invokes `checkSubscription`. The live original function still returns the obsolete Stripe-only `{active}` response despite modern source readback and multiple scoped updates. That response cannot establish Apple/admin membership, purchase eligibility, or verified free status. Its old implementation also masks authentication and Stripe errors as `active: false`; accepting it would be incorrect.

The candidate registers the already-reviewed modern handler under `checkSubscriptionV2`, with all eight runtime files unchanged. Two bridge calls use this fixed name: membership check and the membership refresh after Apple transaction synchronization. The Apple preparation/synchronization endpoint, identity checks, ownership checks, entitlement validation, and failure behavior are unchanged. Installed build 176 needs no native update for this route change.

A fresh name avoiding the old routing fault is an inference from the twelve newer functions serving current code while the original functions serve stale code. It must be confirmed live before switching the bridge. The public Base44 compiler successfully compiled all seventeen current sources; the compiled Worker executed the expected 405/401 behavior with network disabled. This rules out a reproduced source/compiler defect, not an unknown production platform issue.

## Exact prepared production scope

1. Base44 app `69a0e57fa939f578082f8091`: named deployment of **only `checkSubscriptionV2`**. Preserve the existing seventeen function registrations and code. No remote sandbox write, broad deploy, or prune.
2. Verify the new route returns GET 405 and unauthenticated POST 401, and verify the existing seventeen functions are unchanged. If these checks fail, do not switch the bridge.
3. Supabase project `bbkfsgnordtdiblgdzkg`: update **only `app-services`**, using the frozen 55-file current-live package with only `app-services/legacy-billing.ts` changed. Preserve `verify_jwt: true`, import map, secrets, configuration, schema, and every other source file.

The previous authorization named only `checkSubscription`; the two operations above require exact approval under the repository's Production safety rule. TestFlight is postponed by the user's latest instruction.

## Reproducible package and validation

Generator: `scripts/package-membership-v2.py`, with `--live-app-services` pointing at a fresh `get_edge_function` JSON snapshot and `--output` at a new directory. It rejects an unexpected function/version/configuration, unsafe paths, changed baseline bridge, and any bridge edit beyond the fixed route change. The normal local app-services tree includes other unreleased changes and is deliberately excluded.

Prepared package: `.local/apple-limitless178/membership-v2-frozen` at the repository root. Frozen live baseline: app-services version 7, bundle SHA-256 `7fcfa6ed615ff40755d3178d809a1f65b9b4efab74e145894ca1eafda8c383df`.

- Actual generated Base44 handler plus exact frozen Supabase bridge: **25 steps passed**, no network/environment permissions.
- PostgreSQL-backed billing regression: **11 passed**, covering weekly/monthly restore, ownership, expiry/revocation, and durable retries.
- Generated handler and exact frozen app-services entrypoint: typechecks passed.
- Official compiler/local Worker: new function GET 405, unauthenticated POST 401, original name absent in this single-function package; no outbound requests.
- Independent review: no blocking findings.
- Candidate and rollback each contain exactly 55 files; only the candidate bridge differs from live.

Use `--no-lock` for repeated Deno checks so validation cannot add a deployment file. Recheck manifests and current production baselines immediately before an approved action.

## Rollback and acceptance

`supabase-rollback/source` retains the exact live 55-file version-7 snapshot. Redeploying it restores prior behavior, including the unresolved original-route failure; it is not described as a known-working membership fix. An unreferenced V2 function can remain without changing current clients.

No real-account membership refresh, purchase, restore, or Apple sign-in success is claimed. Apple Sign In is a separate investigation: native credential exchange reaches server persistence, but the terminal handoff failure remains unlocalized. TestFlight and signing are outside the current work phase.

## Authorized execution

The user approved: “Да, примени эти две правки”. Named Base44 deployment completed at approximately 18:53 UTC. Fresh inventory contained 18 functions; all prior seventeen function sources/registrations/automations were unchanged and the eight new runtime files matched. All six public GET/POST checks across three routes returned the expected 405/401.

Only after that gate passed, app-services was updated to version 8. Fresh live-v7 preflight matched the frozen baseline. Readback verified all 55 exact source bodies, with only the bridge differing; JWT verification and import map remained enabled. Supabase readback normalizes away the submitted common `source/` path prefix, which is recorded explicitly. Bundle SHA-256: `89d348c3d9ec10bfc9660512de0629e70287001b2842e39e0c90de5b65720751`.

Post-deployment Apple broker probes passed 12/12. These negative/protocol checks do not establish successful phone login. The user then repeated Apple sign-in in installed176; investigation continues on that fresh attempt. See [execution evidence](evidence/full-app/build179/deployment.json).
