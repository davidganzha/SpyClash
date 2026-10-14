# Native StoreKit delivery recovery — build 176

Execution status: **PASS — 49/49 full Staging native tests, including all 8 new recovery regressions**, reported by the parent task on 2026-10-14. Independent review agreed that the saved-transaction recovery blocker is closed. This evidence does not represent a physical purchase, restore, production change or App Store/TestFlight publication.

## Problem and change

The durable app-service journal keeps one unresolved intent per account/service/action. If signed StoreKit payload A reached the server but its acknowledgement was lost, reopening the app with a renewed payload B made `membership/sync_transaction` reject B as `app_action_recovery_required`. No caller could drain the saved A automatically.

Only this StoreKit route now uses a separate cancellable FIFO. When its saved intent differs from the current payload, it replays A with the original request UUID and exact saved body, verifies the canonical response, acknowledges A, and then sends B as its own new request. A's response is discarded and cannot finish B or become B's returned membership state. Retrying unchanged A still uses A's original UUID directly. The generic journal's one-intent behavior and 32-entry limit are unchanged, so this fix creates no unbounded per-JWS queue.

## Preserved boundaries

- The pending reader validates account, service/action, UUID, source/body agreement and absence of credentials before recovery.
- Each await is fenced by the account's session generation; logout during A leaves its journal entry intact and prevents B from being sent or finished.
- A retryable failure or HTTP401/408/425/429 retains A. A definitive nonretryable other4xx may retire A before B is independently attempted.
- Base44 bearer is attached only to the outgoing wire body; Supabase bearer remains only in Authorization. Neither is persisted in the journal.
- Cancelling a queued service request cannot cancel another request's current verification. The existing coalesced StoreKit delivery task semantics are unchanged.
- Server receipt A is never used to acknowledge or finish current StoreKit delivery B. AppStoreTransactionDeliveryStore still checks B's canonical response before invoking B's finish closure.

## New regression cases

In `SpyClashSupabaseStagingTests/SupabaseSessionTests.swift`:

1. `testAppStoreLostACKReopenDrainsExactAThenVerifiesChangedBWithoutFinishingFromA`
2. `testAppStoreRecoveryReceiptACannotFinishBWhoseOwnACKIsLost`
3. `testAppStoreExactPayloadRetryRetainsOriginalIDWithoutExtraRecoveryDelivery`
4. `testAppStoreRecoveryNeverReplaysSavedJWSForAnotherAccount`
5. `testAppStoreLogoutDuringRecoveryRetainsAAndNeverSendsOrFinishesB`
6. `testAppStoreRecoveryKeepsRetryableFailureAndCanAdvanceAfterDefinitiveRejection`
7. `testAppStoreCancelledQueuedDeliveryDoesNotCancelCurrentVerification`

In `SpyClashSupabaseStagingTests/SupabaseMutationJournalTests.swift`:

8. `testAppStorePendingReaderKeepsExactIntentAndRejectsCorruptOrCredentialBearingStorage`

The HTTP fixtures simulate `URLError.networkConnectionLost`, instantiate a fresh session/journal for reopening, compare exact outgoing UUID/body pairs, verify separate credentials, return differing A/B canonical states, and exercise the real delivery-store finish gate. Synthetic JWS strings stand in for already locally verified StoreKit payloads; these tests do not verify Apple's signature service or a live purchase.
