# LIMITLESS — Apple IAP restoration

## Scope and provenance

Native iOS + the canonical Base44 membership/Apple verifier integration.
The user explicitly authorized IAP inside the build and deferred Stripe.
No production deployment, configuration change, purchase, App Store upload or
review submission is part of this checkpoint.

- Baseline: build 135, commit `737d0d1` (current Radar/profile-fanout fixes).
- Restoration reference: `a9008aa`, the last complete native LIMITLESS snapshot.
- Checkpoint build: **1.0.1 (136)**, branch `davidganzha/restore-limitless`.
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

## Rollout — disabled by default

| Server configuration | Result |
| --- | --- |
| No flags, or `SPYCLASH_LIMITLESS_ENABLED` other than exact `true` | Current universal CASADA access; no Apple purchase required |
| `SPYCLASH_LIMITLESS_ENABLED=true` only | Verified FREE/LIMITLESS access; new purchases closed; existing Apple purchases can be restored |
| Both that flag and `SPYCLASH_LIMITLESS_APPLE_PURCHASE_ENABLED=true` | Apple purchase preparation permitted, subject to membership and Apple configuration checks |

These are **shared backend policy flags**, not per-device settings. Activating
the first flag affects generation/customization requests from older iOS and web
clients too. Do not enable it in production without an explicit migration
decision, particularly while web/Stripe work is deferred.

The Apple-only resolution path does not call the deferred Stripe integration.
Existing verified provider records remain readable until their stored expiry;
the legacy Stripe implementation has not been upgraded or reactivated.

## Future deployment set (requires fresh approval)

1. Add `MembershipSignal` with owner-read/admin-write RLS.
2. Deploy matching bundles for `app-store-entitlement`, `checkSubscription`,
   `generateWordPack`, `communityAction`, and `deleteAccount`.
   Deploy entity + deletion cleanup before enabling signal-producing functions.
3. Keep rollout flags disabled until Apple sandbox acceptance and the shared
   client migration plan are approved. Never deploy the stale web backend bundle.

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

- iOS suite: **401 passed, 0 failed, 0 skipped**.
- Affected backend suites: **228 passed, 0 failed**; all five function entry
  points pass `deno check`.
- Release-gate regression suite: **43 passed, 0 failed**.
- Debug and Release iPhone Simulator builds succeed. The actual Release
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

Read-only production preflight found the existing `app-store-entitlement`
function and all required Apple IAP secret names on SpyClash app
`69a0e57fa939f578082f8091`. Neither rollout flag name is currently configured.
Secret values were not displayed; presence alone does not verify key validity,
product availability, agreements or sandbox acceptance. Production remains
unchanged pending exact deployment/activation confirmation, including the
effect on older clients described above.
