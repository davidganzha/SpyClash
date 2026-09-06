# Account lease recovery and its crash boundary

The local change fixes acquisition and release failures in the shared `billing-identity-lifecycle.ts` helper. The canonical source is in `stripe-entitlement-webhook`; `scripts/sync-base44-billing-lifecycle.sh` copies it to the other ten callers. No schema change is required. These runtime changes have not been deployed.

## Recovery implemented

- If acquisition writes its candidate lease but confirmation fails, the helper clears that exact unpublished candidate before reporting the acquisition failure. No action has received a lease handle at this point, so no protected business write is authorized by this acquisition.
- If a lost acquisition response may precede a delayed commit, cleanup also fences the original observed revision. The candidate cleanup and previous-revision fence use bounded compare-and-swap operations. Whichever commits first invalidates the delayed acquisition; a race where acquisition lands between the two comparisons is reconciled and retried. New revision values are never rolled back to old values.
- Abandoning a retry of an existing deletion preserves `state: deleting`. Abandoning a fresh writer/issuance acquisition restores the preceding active state. Cleanup never clears another owner, recreates a deleted lifecycle row or removes an existing deletion tombstone.
- Legacy rows without a usable revision now include the observed revision value or its absence in their timestamp-based comparison. A newly installed revision invalidates a delayed legacy acquisition even if the datastore timestamps happen to be equal.
- A missing or malformed acquisition update count requires confirmation, instead of looping and colliding with the lease that the same call just wrote. Only the numeric value `0` establishes a rejected acquisition; coercible values such as `null`, `false` or `"0"` do not. Cleanup and release likewise require exact numeric success or a reconciled read.
- All callers receive up to three exact release/reconciliation attempts, including callers without an outer cleanup retry loop. Lost responses and temporarily failed confirmation reads can recover during that release. A replacement owner or deleted row requires no further cleanup by the former owner. Permanent failure still throws a typed error and retains protection; it is not reported as successful release.

Acquisition abort performs at most three rounds of candidate cleanup, previous-revision fencing and reconciliation. Each storage call is awaited. These are operation-count bounds, not a promise that an already-started storage request always completes within a fixed wall-clock time. Existing caller-specific retries may add their own outer bounds.

## What remains impossible to claim

The ten-minute lease lifetime and account-deletion checks are unchanged. Once a lease handle has been returned, a process that died and a process paused just before a protected write can present identical stored lifecycle state. The current code reads the lifecycle entity and writes the protected entity in separate datastore operations. An observer cannot safely distinguish those two executions merely by waiting for a heartbeat or retrying a request.

Consequently, clearing such an active lease early could let account deletion or a new writer proceed while the paused old writer resumes. A shorter TTL, a deployment-time unlock or a heartbeat alone does not establish safety. Cleanup in this patch covers executions that can still run their cleanup code; a hard kill can still retain a published lease until expiry. The existing expiry protocol also depends on its documented assumption that the lease outlasts an invocation. These tests do not prove the hosting platform's maximum process lifetime or suspension behavior.

Removing that limit requires an atomic persistence boundary for each protected operation: validating the account's current fencing epoch/deletion state and committing the associated write must succeed or fail together. New-row creation must participate too; tagging an already-created row with an epoch does not prevent a late creation after deletion. A concrete next protocol would:

1. Provide a transaction-capable persistence adapter, or a backend-owned atomic write primitive, covering account admission/deletion state and each protected write.
2. Make every writer, including account provisioning, AI/quota persistence, room signals, push records and deletion cleanup, pass the admitted account epoch into that primitive.
3. Reject old-epoch writes atomically after deletion begins, drain incompatible old runtimes, and then shorten or remove the coarse account lease only where that primitive protects every write and creation.
4. Inject a pause immediately after admission, begin deletion/new ownership, resume the old write, and verify that the datastore rejects it. Separately test lost provider responses; entity fencing does not by itself guarantee an external AI call happens exactly once.

This is a protocol and persistence change, not an additional retry loop. The current runtime patch does not silently introduce that change or claim deployment-wide crash safety.

## Validation

Twenty new fault-injection tests cover committed/uncommitted lost acquisition responses, verification outages, a delayed CAS between cleanup steps, legacy revision absence, missing and malformed update counts, lost cleanup responses, permanent outages, deletion retries, unpublished issuance, replacement owners, deleted rows and unchanged expiry protection. Four existing lifecycle suites now assert that an unpublished orphan is cleared rather than intentionally left blocking.

The eleven caller function suites passed 953 tests (including eleven actual-generation-handler steps), zero failures, with the final helper changes. All eleven runtime copies are byte-identical. The generation HTTP harness was subsequently extended to thirteen passing steps, including lost legacy create responses and failed post-create confirmation reads: neither grants an unverified successful response, and a later confirmed replay performs no new quota or provider action. Runtime isolation, helper type checking and diff whitespace checks pass. These are local fault-injection checks; they do not establish deployed or physical-device acceptance.

Local logs: `/tmp/spyclash-shared-lease-final-caller-tests.log`, `/tmp/spyclash-lease-recovery-new-tests.log` and `/tmp/spyclash-generation-main-operation-tests.log`.
