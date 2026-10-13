# Main hybrid authentication and account deletion preparation

This is local source preparation for build 173. No production function, provider configuration, database, account or App Store state was changed by this work.

## Identity and provider routing

Email/password, registration, six-digit OTP and password recovery keep the existing Base44 service. Apple and Google finish the existing canonical Base44 broker first. A real Base44 bearer is then independently checked by `legacy-session` against `User/me`; only its verified immutable `id` selects the Supabase identity. Contact-email equality and client metadata never establish ownership. Supabase and Base44 credentials remain separate.

The broker source verifies Apple signature/JWKS, issuer, audience, nonce, code redemption and matching subjects before provisioning. Google additionally verifies `azp` when present, verified email and its browser transaction state. These checks are already present; this review did not replace provider verification or create a new paid provider.

Read-only inspection on 2026-10-13 found the canonical `/MobileAuthCallback.html` route returning HTTP 200. Its entry script `/assets/index-DX97ZPnq.js` contains the exact callback route, fixed `spyclash://auth` handoff and safe error handling, without localStorage in that entry script. The source callback tests passed 48/48. This is not a successful real Google login, nor proof that all remote secrets and provider console settings match the local source. Both Google and Apple still require real completion with the main app identity before release acceptance.

Linked Supabase sessions require a live Auth session row and Base44 revalidation at most every 65 minutes on the server. Native refresh re-exchanges the legacy token before expiry. Source-token revocation is therefore bounded rather than instantaneous; deleting through the main coordinator fences application access immediately.

## Full account deletion contract

The separate staging app keeps its existing copy-only deletion. The main candidate refuses copy-only deletion in its UI and client. Main deletion remains disabled by default (`mainAccountDeletionEnabled: false` in client configuration; `APP_MAIN_ACCOUNT_DELETION_ENABLED` must explicitly be `true` on the server).

The prepared main request is `profile/delete` with `deletion_scope: "account"`, its durable `request_id`, and a transient `base44_access_token`. The native journal and server command hash exclude the provider credential. No provider bearer is persisted in deletion intent or receipts.

The server independently verifies the original account, rejects administrator/unclassified roles before deletion, and checks its immutable legacy link. It reserves one deletion intent under the exclusive account lock and changes the profile to `deleting` before calling Base44. Concurrent requests cannot start a second provider delete. Only a provider response containing `success: true` and a receipt matching the exact request and verified legacy subject marks `legacy_deleted` and permits Supabase content deletion. Supabase Auth cleanup follows through the existing durable job. The response preserves `manual_apple_revocation_required`.

HTTP 503 `account_deletion_pending` means the original deletion has not been confirmed; it must retain the native request. A 401 from Base44 after a lost deletion response is deliberately not treated as proof of deletion. The account remains fenced. A retained `legacy_deleted` marker allows the same request to finish Supabase cleanup without trying to authenticate an already deleted Base44 user.

## Receipt recovery implementation and deployment prerequisites

The receipt protocol is implemented locally in `base44/functions/deleteAccount/deletion-receipt.ts`. It is not published. A 32-byte server-only `APP_DELETION_RECEIPT_SECRET` derives a stable HMAC capability from the Supabase actor and request UUID. The Base44 request carries that capability only transiently. A new private `AccountDeletionReceipt` entity stores its SHA-256 hash, the immutable request and subject hash, phase, expiry and a temporary original user ID. It does not store the capability or provider bearer. Capabilities expire after 30 days; retain the configured recovery secret unchanged until every pending deletion is complete.

The canonical deletion function prepares a receipt only after verifying its original ordinary user. It marks `user_delete_ready` only after all existing content/credential cleanup and before deleting `User`. A status request without a user bearer can confirm exact `User` absence only after this marker; mere 401/404 never confirms erasure. Completion scrubs raw user IDs from every equivalent receipt row, including duplicate creates or partially acknowledged updates. The receipt grants no login or general account operation.

The Supabase coordinator checks a public `deletion_capabilities` response before starting deletion. This preflight sends **no Authorization, access token or cookies** (`credentials: omit`): an older Base44 function must fail unauthenticated rather than mistake a capability probe for an authenticated deletion. Missing/malformed recovery configuration or missing protocol support leaves the profile active and refuses deletion.

Retries can consume the receipt even after the original bearer is invalid. The existing authenticated maintenance route now runs a bounded main-deletion recovery pass before Auth cleanup. It needs no native session or stored user credential and can finish a lost-ACK deletion after normal sign-in expires. Maintenance remains protected by its server worker secret and gateway authorization; a schedule must be enabled and verified before this capability is enabled.

A fresh read-only canonical pull found the current entry and ten support modules identical to local HEAD. `billing-identity-lifecycle.ts` has a constructor-signature difference. The reviewed deployment bundle at `base44-prepared/deleteAccount` preserves **all freshly pulled support files**, including that drift, and changes only `entry.ts` plus the new receipt module. Use this prepared bundle, not a blind replacement from the older local function folder. Evidence is in `evidence/full-app/build173/delete-account-baseline.json`.

Before enabling main deletion, separately approve and deploy the private entity and the prepared canonical `deleteAccount` function, the Supabase migration/function updates, the recovery secret and authenticated maintenance schedule. Then verify on disposable accounts, including a lost final response. Main client/server capability flags remain false in this candidate. No receipt extension, secret, schedule or production function was deployed here.

## Data continuity and evidence

Own profile, packs and bounded resumable history import still run before issuing a session. Friendships/comments require the existing private social export/reconciliation path and verified mappings for both participants; the normal sign-in bridge does not promise all historical relationships have been imported. Before cutover, reconcile a fresh source snapshot and review unresolved mappings.

Local verification: the full application suite passed 75/75 against isolated PostgreSQL/Auth, including 9 deletion cases; Base44 deletion tests passed 34/34, including 6 receipt cases. The HTTP regression uses a real local Auth session and an actual loopback server, proving that a deleting profile rejects normal access but accepts the saved deletion retry. Cross-provider tests run the actual receipt module with in-memory Base44 stores and mock network responses: they prove lost-ACK recovery, no-session worker completion, capability isolation, wrong-secret rejection and credential-free persistence. These are not live original-account deletions. The migration is local preparation only; cloud and physical-device acceptance are separate.
