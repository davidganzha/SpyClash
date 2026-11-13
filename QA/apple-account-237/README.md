# Apple purchase investigation and diagnostic correction — build 237

## Confirmed runtime evidence

The affected iPhone has TestFlight 1.0.4 (232). Its relevant purchase/session code matches source 236. The currently published Supabase `app-services` is v26. No production changes are part of this investigation.

The two sign-in methods use separate billing authorities:

- Game Center uses the native Supabase Apple account registry. The 2026-11-13 00:31:48 UTC receipt is HTTP 409, `purchase_owner_mismatch`, specifically `This purchase is not bound to the signed-in account.` This rejects the token owner before entitlement ownership is checked. The same failure existed on v25 before the connection change. A successful prepare issues a stable token; it cannot rebind an older Apple transaction.
- Sign in with Apple uses the Base44 identity bridge and Base44 `AppStoreAccount`. Its syncs at 00:35:59, 00:36:19, 00:36:23 and 00:47:03 UTC returned HTTP 200 with explicit canonical verification and an expired sandbox weekly subscription ending **2026-10-23 19:45:13 UTC**. The published Base44 handler was inspected, including its canonical Apple status request and monotonic persistence. It has no cached-record verification bypass. The stored verification timestamp advances with these requests.

The latest screenshot is a third, separate observation: `IAP-RESTORE-APPLE-NONE: STOREKIT_UNKNOWN`. The client reaches `AppStore.sync()` only after reconciling history without finding active access. That Apple synchronization call fails. This is not the native 409 and is not an HTTP server-verification failure.

## Captured device transaction

During a user-initiated Restore, a read-only copy of the app's own mutation journal captured its signed transaction. The journal request was correlated to the exact server receipt at **2026-11-13 00:50:34.715074 UTC**: HTTP 200, `success:true`, `server_status_verified:true`, expired October 23.

The captured token, original transaction and transaction identifiers all match the same Base44 entitlement and its owner. The signed payload contains an October 22 renewal, October 23 expiration, and November 13 signing time. This establishes that this Restore submitted an old transaction; it did not submit a new transaction that our server replaced with an old database row. The signing time is not a new purchase date. Independent cryptographic verification passed in official Edge Runtime 1.77.9 with the exact v26 compatibility adapters, Apple SDK 3.1.0, all three public Apple roots and online OCSP checks. The expected Production-environment rejection also passed. A read-only Supabase query found no native billing binding for this captured token.

Raw identifiers, JWS, device journal and account records are retained only in the ignored `.local/iap-409-private` directory (directory mode 0700, files 0600). They are excluded from this checkpoint. Polling stopped after capture. No purchase, Restore, account reset, transaction finishing, app replacement or ownership transfer was initiated by tooling.

The captured Restore is the Apple-sign-in path. Its token origin does not independently prove the token submitted during the earlier Game Center purchase attempt. The exact cause of `AppStore.sync()` returning `unknown` remains unproven. The user confirmed that Apple's payment sheet did appear and that they confirmed checkout; do not reinterpret those attempts as never having opened Apple's sheet.

## Successful device acceptance

A later user-initiated checkout prepared at **00:53:03 UTC** and synchronized successfully at **00:53:16.822273 UTC**. Its canonical response was active, with sandbox expiration **2026-11-14 00:53:09 UTC**. Subsequent syncs at 00:53:43, 00:53:47 and 00:54:18 were also active. The Supabase membership mirror was read back as active with that same underlying subscription expiration. Its short cache expiry is separate from the Apple subscription expiration.

The user explicitly confirmed **“Да, LIMITLESS работает”** in the app. This establishes successful Apple-sign-in purchase/access on the existing TestFlight build 232 without another deployment or app replacement. It does not establish Game Center access to the same subscription, nor prove which of the user's preceding attempts cleared the old transaction state.

## Scoped source change

The client previously reduced every ownership rejection to generic HTTP 409 and advised repeated Restore. It also described a verified but inactive purchase as a verification failure. The correction:

- Maps only the exact server code `purchase_owner_mismatch` to the closed `ACCOUNT_BINDING` diagnostic.
- Reports `NO_ACTIVE_SUBSCRIPTION` after an acknowledged purchase has no active access.
- Provides specific English, Russian, Spanish and Ukrainian guidance for these outcomes.
- Keeps transaction finishing after canonical server acknowledgement, including expired transactions, and grants no access to inactive purchases.

There is no ownership reassignment, verification bypass, automatic new purchase or change to Restore behavior. Build settings are synchronized at 237; marketing remains 1.0.4. This is a diagnostic correction, **not a claim that device purchases are repaired**. No native build was uploaded and no backend was deployed.

## Validation

- Fifteen native billing integration tests passed, including two new cases with zero prior entitlements: prepared new token plus foreign historical token, and prepared token plus unknown historical token. Ownership remains unchanged, no foreign access is granted, and the original owner can restore idempotently.
- A separate local reproduction against the v26 candidate passed 14 receipt/domain cases with injected verified Apple records. It reproduces the ownership rejection, not Apple's on-device purchase behavior.
- All **72 Swift MembershipTests passed, zero failures or skips**, using a signed Simulator test build. Three new cases cover binding rejection without finishing, private error data exclusion, verified inactive deliveries finishing without access, active delivery, and all four language variants. An initial build in the Documents worktree failed signing because generated products acquired Finder metadata; rebuilding in `/private/tmp/SpyClash-IAP-237-DerivedData` preserved signing and passed. No product signing configuration was weakened.

## Remaining acceptance

Apple-sign-in purchase and active access are accepted on the phone. Game Center remains a separate SpyClash account with a separate billing registry; automatic subscription/account linking is not implemented or claimed. Any account linking, transaction ownership migration, test-history reset, production deployment or TestFlight upload requires a separately reviewed action and current approval. No server or app publication is needed to explain the successful device result above.
