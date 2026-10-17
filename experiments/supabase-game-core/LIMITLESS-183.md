# LIMITLESS verification in 182 and retry repair in 183

17 October 2026. Build 182 remains the installed and distributed TestFlight build. The source candidate is 1.0.3 (183); it has not been signed, uploaded or deployed by this change.

## Physical TestFlight result

On the paired iPhone, the installed app identified itself as 182 and retained the existing account. Its LIMITLESS page loaded the weekly App Store price, showed `CURRENT LIMITLESS`, and displayed all three capabilities as active.

An explicit **Restore Purchases** completed successfully. The app displayed: “An active App Store purchase was found and verified. LIMITLESS access is confirmed.” A corresponding live operation at **21:34:15 UTC** completed with `success=true`, `server_status_verified=true`, an active weekly Apple sandbox entitlement, and an active membership snapshot. Apple expiration was 18 October 2026 at 19:44:41 UTC.

**Refresh Access** then confirmed active access. After terminating and relaunching the installed app, its profile still displayed `LIMITLESS is active`. No `ACCESS_UNVERIFIED` appeared during these checks. Device screenshots remain in ignored `.local/limitless183/phone`; their hashes and a redacted server result are in `evidence/full-app/build183/limitless-build182-device-verification.json`.

This proves restoration, verification and persistence of the existing subscription in 182. It does **not** prove a new first purchase in 182: this account was already subscribed, so the app correctly offered refresh and management rather than another purchase.

## Reproduced defect and repair

The live Supabase billing bridge replaced an explicit temporary Base44 `apple_account_binding_busy` response with `legacy_billing_rejected`. In addition, the hybrid client path returned before the original native binding-retry loop. A transient binding lease could therefore fail transaction delivery or Restore instead of completing after a short retry.

The candidate changes only this behavior:

- The server preserves the typed signal only for `app-store-entitlement / sync_transaction`, HTTP 503 and the literal boolean `retryable: true`, using a fixed sanitized message.
- Both native transports share bounded delays of 500 ms, 1 s and 2 s. The hybrid path retains the same delivery queue lease, request ID, signed transaction and account throughout retries, including recovery of saved deliveries.
- Cancellation or account change stops delivery. Exhausted retries keep the unfinished intent. `Product.purchase` is never retried by this loop, and no new purchase is created during Restore.

The existing fail-closed membership and Apple ownership/signature checks remain. A genuinely unavailable access check still prevents starting a payment; the repair does not grant access merely to suppress an error message.

## Validation and limits

- Native membership, catalog and direct retry suites: 90 passed, 0 failed.
- Hybrid session/journal/retry suites: 56 passed, 0 failed, including 8 new targeted regression tests.
- Expanded server bridge suite: 13 passed. Fresh actual Apple and membership handler pipeline: the busy case failed before the patch and all 11 cases passed after it. Membership handler contract: 25 passed. Exact candidate database suite: 10 passed. Deno typecheck passed.
- `SupabaseRelease` unsigned archive succeeded. All 12 archive checks passed, including app/widget 183, unchanged live backend configuration, and exclusion of StoreKit test fixtures.
- Independent source review found no blocking issue. The server candidate is the exact 55-file live v9 snapshot with only `app-services/legacy-billing.ts` changed.

Five additional local StoreKit integration tests cover purchase, Restore, unfinished delivery, unknown-access preflight and Ask to Buy. They are opt-in and are **not counted as passed**. The installed simulator runtimes could not establish the local StoreKit test session. A fixture-only canary now requires `Transaction.environment == .xcode` before creating the purchase manager; failures stop before a purchase or App Store sync. The ordinary test run explicitly skips these five tests.

Apple documents this test-environment problem in its [Developer Forums response](https://developer.apple.com/forums/thread/826971) and a fix in the [iOS 26.6 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26_6-release-notes). The official runtime downloader reported that iOS 26.6 arm64 was unavailable. No Apple account or credential settings were changed to work around it. Consequently, a complete new-purchase StoreKit integration result remains open.

## Prepared production scope

1. Update only Supabase project `bbkfsgnordtdiblgdzkg`, Edge Function `app-services`, using `.local/limitless183/deploy/candidate-payload.json`. Retain JWT verification, import map, entrypoint and the other 54 files. No Base44, schema, secret, product or website changes.
2. Sign and upload 1.0.3 (183) as **TestFlight Internal Only**, assigned only to the existing David-and-Dima internal group. No external testing or App Store submission.

Both actions require fresh approval in this chat under `AGENTS.md`; neither is implied by the local checks or GitHub checkpoint. The exact live v9 rollback payload, fresh-drift verifier and post-deploy byte/authentication checks are prepared under `.local/limitless183/deploy`. A deployment readback proves deployed source and authentication controls, not a real purchase or a real contention event.
