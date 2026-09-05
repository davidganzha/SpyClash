# LIMITLESS — Apple IAP restoration

## Scope and provenance

Native iOS + the canonical Base44 membership/Apple verifier integration.
The user explicitly authorized IAP inside the build and deferred Stripe.
After the local restoration checkpoint, the user explicitly confirmed production
activation, including its impact on older iOS and web clients. The approved
server deployment and two rollout flags are now active. No Apple payment,
App Store upload or review submission was performed.

- Baseline: build 135, commit `737d0d1` (current Radar/profile-fanout fixes).
- Restoration reference: `a9008aa`, the last complete native LIMITLESS snapshot.
- Restoration checkpoint: **1.0.1 (136)**, commit `a6c1cd7`.
- Production activation checkpoint: **1.0.1 (137)**, branch `davidganzha/restore-limitless`.
- Working copy: `SpyClash.worktrees/restore-limitless`. Original checkout unchanged.
- Stripe checkout/webhook files and the web worktree have no changes.

Rather than replacing current AppState, profile, game, or realtime files with
old versions, the restored feature uses small native membership, StoreKit and
pricing components. The old StoreKit file is a local diagnostic fixture only;
its price is not a live retail price.

## Behavior

- StoreKit 2 loads the existing weekly product's localized price. No hardcoded
  retail price and no web checkout link appear in the iOS purchase flow.
- Purchase preparation reserves the authenticated account token on the server.
  Signed transactions require canonical Apple server verification before being
  finished. Identical in-flight deliveries are coalesced.
- Pending, cancelled, failed, restored and verified states are distinct. Account
  switches and same-account token rotation invalidate cached access and pending
  delivery results. Restore is the only action that calls `AppStore.sync()`.
- Active access, grace periods, expiry, revocations, refunds and admin grants
  resolve from server-owned records. Network errors never become verified FREE
  status or a purchase offer.
- Native realtime consumes an owner-scoped `MembershipSignal` with no payment
  identifiers, plus existing admin-grant signals. Raw Entitlement RLS stays
  admin-only. Activation, expiry and bounded foreground refresh recover missed
  signals. Signals are removed by account deletion under existing coordination.
- Restored FREE presentation: 10 AI generations/day, latest 5 matches, basic
  avatars/styles. LIMITLESS provides unlimited daily AI generations, full history,
  advanced statistics and customization. Existing saved premium styles are
  retained; the newer eagle avatar remains free.
- AI quota and new premium profile selections are enforced server-side.
  History/statistics are presentation benefits: existing owner-scoped historical
  data reads are intentionally not removed or converted into a privacy boundary.

## Rollout — defaults closed, explicitly enabled in production

| Server configuration | Result |
| --- | --- |
| No flags, or `SPYCLASH_LIMITLESS_ENABLED` other than exact `true` | Current universal CASADA access; no Apple purchase required |
| `SPYCLASH_LIMITLESS_ENABLED=true` only | Verified FREE/LIMITLESS access; new purchases closed; existing Apple purchases can be restored |
| Both that flag and `SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED=true` | Apple purchase preparation permitted, subject to membership and Apple configuration checks |

These are **shared backend policy flags**, not per-device settings. Activating
the first flag affects generation/customization requests from older iOS and web
clients too. The user explicitly accepted this shared-client effect before
production activation. Any future production change still needs fresh approval.

The Apple-only resolution path does not call the deferred Stripe integration.
Existing verified provider records remain readable until their stored expiry;
the legacy Stripe implementation has not been upgraded or reactivated.

## Approved production deployment — 2026-09-05

1. Added `MembershipSignal` with owner-read/admin-write RLS. All 24 pre-existing
   entity definitions were preserved exactly; postflight schema count is 25.
   The authoritative schema sync reported existing schemas as updated, but their
   JSON definitions were independently verified unchanged.
2. Deployed `deleteAccount` first, then `app-store-entitlement`,
   `checkSubscription`, `communityAction`, and `generateWordPack` from `a6c1cd7`.
   The prepared baseline also includes its profile-fanout lease/retry hardening
   and CommunityProfileSignal account-deletion cleanup, absent from the former
   production bundles. No newer remote changes were overwritten.
3. Pulled all 17 functions back. The five deployed runtime bundles match the
   reviewed local source byte-for-byte (63 runtime files); the other 12 function
   bundles are unchanged, including Stripe checkout and webhook.
4. Set only `SPYCLASH_LIMITLESS_ENABLED=true` and
   `SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED=true` on canonical app
   `69a0e57fa939f578082f8091`. No site, authentication or Stripe configuration
   was changed. The user approved activation before sandbox purchase acceptance;
   activation does not establish end-to-end Apple purchase readiness.
5. Authenticated live `checkSubscription` changed from universal CASADA to
   `protocol=limitless`, `tier=free`, `apple_purchase_enabled=true`, FREE benefits
   of 10 AI generations/day and latest 5 matches, and healthy entitlement,
   admin-grant and quota reads. Stripe resolution reports `not_required`.
6. Authenticated `app-store-entitlement` `prepare` succeeded for
   `com.spyclash.ios.limitless.weekly` with a valid account-binding UUID. This
   exercises/reserves the normal account binding, not a charge or paid grant.
   No account-binding value was exposed in the evidence.

Backups and independent pull-back evidence are retained locally under
`/tmp/spyclash-limitless-production.tAZyr4`. The production secret values were
not printed or saved. Reverting flags or deploying a rollback requires a new
explicit production instruction; do not apply the stale web backend bundle.

Verify Apple configuration independently: `APPLE_IAP_BUNDLE_ID`,
`APPLE_IAP_PRODUCT_ID`, `APPLE_IAP_APPLE_ID`, `APPLE_IAP_KEY_ID`,
`APPLE_IAP_ISSUER_ID` and one of `APPLE_IAP_PRIVATE_KEY_P8` /
`APPLE_IAP_PRIVATE_KEY_P8_B64`. Store keys only in the platform's secret storage.
The expected native product is `com.spyclash.ios.limitless.weekly`.

## Release acceptance still required

- Real Apple sandbox purchase, pending approval, restore on a second iPhone,
  account mismatch, renewal, expiry, refund/revocation and failed-delivery retry.
- Verify server-to-server notifications, scoped realtime delivery and deletion
  cleanup on the deployed matching backend.
- Confirm current product availability/price and Apple agreements in App Store
  Connect. Neither source constants nor the local fixture prove portal state.
- Align the public privacy policy and App Privacy with native Purchase History
  collection. Native policy/terms and the manifest are prepared in this branch.
- Review Notes must describe this IAP-enabled build, not reuse the free-only
  submission notes. Reviewers must be able to exercise the purchase flow; a
  universal-access configuration with hidden purchases is not IAP review readiness.
- Build/sign a device archive and rerun the signed release gate before any upload.

Reference: [Apple subscription integration and review guidance](https://developer.apple.com/app-store/subscriptions/).

## Local verification

Verified on 2026-09-05:

- iOS suite on build 136: **401 passed, 0 failed, 0 skipped**. Build 137 changes
  only the synchronized build number and this deployment evidence.
- Affected backend suites: **228 passed, 0 failed**; all five function entry
  points pass `deno check`.
- Release-gate regression suite: **43 passed, 0 failed**.
- Debug and Release iPhone Simulator builds succeed. Build 137 was rebuilt in
  Release and passed the actual Simulator release gate. The Release
  Simulator application passes the release gate in `--simulator` mode; this
  does not validate a device signature or App Store readiness.
- Russian LIMITLESS screen visually inspected on the iPhone 17 Simulator using
  preview data. No purchase or live backend call occurs in that UI preview.

The repository's release gate now requires StoreKit, the expected product and
Purchase History, while retaining signing/widget/icon/audio/privacy checks and
rejecting bundled local StoreKit fixtures. Simulator Debug inspection accounts
for Xcode's separate application dylib.

UI-only smoke: launch Debug with `--spyclash-ui-preview`,
`--spyclash-preview-tab=profile`, `--spyclash-preview-lang=ru`,
`--spyclash-preview-limitless`, `--spyclash-preview-sheet=limitless`.
This path does not make purchases or call the backend.

Read-only production preflight found the existing Apple verifier and all
required Apple IAP secret names; both rollout flags were absent before this
activation. Presence alone does not verify private-key validity, product
availability, agreements, renewals or sandbox acceptance. Filtered error logs
for the five deployed functions contained no matching entries in the initial
post-deployment check; fresh real purchase traffic remains required.
