# checkSubscription runtime reconciliation candidate

Target: Base44 application `69a0e57fa939f578082f8091` (SpyClash), function **checkSubscription only**. This directory is a local deployment candidate. It has not been deployed and does not authorize a production action.

The `base44/functions/checkSubscription` directory contains the eight runtime files retrieved by the fresh 2026-10-17 Base44 pull, flattened without modifying their bytes. `source-manifest.json` records their hashes. The local function configuration points to `entry.ts`. Tests and packaging helpers are outside the runtime function directory. There are no entities, website assets, auth configuration, secrets, or other functions in this project.

## Evidence and limits

The credential-free server-side probe observed HTTP 200 with only the `active` field on all three public routes: the custom-domain API route, the custom-domain `/functions/checkSubscription` route, and the `base44.app` API route. The freshly pulled handler instead rejects unauthenticated requests with HTTP 401 and returns the complete membership contract for verified users. This establishes a public runtime/source contract mismatch. It does **not** establish the exact response received by the linked account on the phone: an authenticated live billing probe was not performed because it can reconcile billing records.

The unchanged Supabase bridge rejects an `active`-only success body with `legacy_billing_response_invalid` / HTTP 502. The actual bridge is exercised by the local contract tests. This is consistent with the HTTP 502 observed around the reported LIMITLESS failure, but is not a phone-level end-to-end reproduction.

The reason Base44 serves behavior different from its pulled source is unresolved. Redeploying the isolated modern bundle is a narrow proposed reconciliation, not proof that the runtime will switch. A source readback or matching hash alone cannot establish successful deployment. The current pulled modern source is also **not a faithful rollback artifact** for the observed `active`-only runtime. Do not represent it as one.

## Local verification

From the repository root:

```sh
python3 experiments/supabase-game-core/evidence/full-app/build178/check-subscription-candidate/package.py
deno test --config experiments/supabase-game-core/evidence/full-app/build178/check-subscription-candidate/tests/deno.json experiments/supabase-game-core/evidence/full-app/build178/check-subscription-candidate/tests/contract_test.ts
```

Use the installed Deno executable if it is not on the shell path. The test suite runs the actual candidate handler with explicit SDK/Stripe fixtures and calls the unchanged bridge with an in-memory database and fetch fixtures. It grants no network or environment permissions. It covers unauthenticated calls, incorrect app context, invalid identity, verified FREE/Apple/admin access, expiry, purchase rollout gating, provider outages, and rejection of both old `active`-only shapes. Stripe construction and unplanned network calls fail the test.

To reproduce the flattened candidate from the recorded pull, supply the directory containing its eight `.ts` files and a new empty output directory:

```sh
python3 experiments/supabase-game-core/evidence/full-app/build178/check-subscription-candidate/package.py --source .local/apple-limitless178/canonical/base44/functions/checkSubscription/base44/functions/checkSubscription --output /tmp/spyclash-check-subscription-reviewed
```

The packaging helper checks all bytes against the manifest before writing. It performs no application binding, credential handling, API call, or deployment.

## Approval and runtime acceptance

Before any deployment, obtain fresh explicit approval for the exact application and `checkSubscription` operation, as required by the repository's production safety instructions. Verify the CLI's local application binding is exactly the target above. Use the named single-function deployment operation from this candidate project; do not deploy the whole repository, use pruning, or change secrets, rollout flags, the Supabase bridge, Apple purchase logic, or other functions.

After an authorized deployment, verify actual public runtime behavior: a credential-free POST must produce the handler's HTTP 401 JSON contract, not HTTP 200 with `active` alone. Then obtain a real linked-account membership response and confirm the full contract, preserved provider access, and purchase eligibility. Any live authenticated probe must be within the approved production scope because the function can reconcile records. Finally retest build 176's LIMITLESS flow on the phone; Apple purchase confirmation and successful entitlement restoration are separate acceptance steps. If runtime behavior remains unchanged, stop and investigate Base44 serving/deployment state rather than adding a fallback or relaxing membership validation.
