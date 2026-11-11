# LIMITLESS and generation allowance

The candidate retains the existing weekly StoreKit product
`com.spyclash.ios.limitless.weekly`. The read-only App Store Connect snapshot in
`app-store-readiness.json` reports the weekly product as APPROVED; monthly remains
MISSING_METADATA and is not enabled for checkout by this change.

## Access propagation

StoreKit continues to require a locally verified signed transaction, canonical
server acknowledgement, and a fresh resolved membership before reporting a
successful purchase or restore. No entitlement is created by an ad callback or
by local UI state.

Previously, a successful membership refresh did not invalidate the generation
allowance snapshot. A newly purchased LIMITLESS user could therefore retain the
old free allowance and ad offer until the next generation or periodic poll.

MembershipStore now announces actual verified access transitions synchronously.
AppState invalidates obsolete allowance/ad state immediately and requests a new
server-owned generation status. This also covers restoration, approved pending
purchases, realtime revocation, and locally enforced expiry. Universal CASADA
access and verified paid LIMITLESS are distinct for this notification because
they have different generation quota rules. Failed reads retain unexpired
verified membership, while a known expiry still invalidates old unlimited state.
Account changes cannot apply an earlier account's notification or refresh.

GenerationRewardStore owns cancellation and the durable pending ad reward; this
notification does not clear an already-earned reward or invent a generation
credit. The server remains authoritative for every generation request.

## Validation boundaries

Focused MembershipTests cover purchase/revocation notifications, universal-to-paid
transition, expiry without a network poll, expiry during an outage before the
scheduled task runs, and rejection of an earlier account's expiry notification.
The root candidate report records the actual test-run result.

The existing opt-in StoreKitSandboxIntegrationTests use Xcode's local StoreKit
environment with a fixture backend. Even a successful run does not prove a real
Apple Sandbox purchase, production receipt verification, or TestFlight behavior.
The weekly product approval alone is likewise not an end-to-end purchase test.
Real-device purchase/restore acceptance and the final ad-to-credit flow remain
separate acceptance steps; this work did not purchase, upload, submit, deploy,
or change production configuration.
