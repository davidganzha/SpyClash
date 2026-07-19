# Base44 function deployment record

Target app: `69a0e57fa939f578082f8091` (`SpyClash`).

This record documents the narrow production function deployment completed on
July 16, 2026. It did not publish the site, push entity schemas, change auth
configuration, modify connectors, or set/delete secrets.

## Current remote state

The read-only production listing on July 18, 2026 returns the complete reviewed
set of 16 functions listed below. The earlier five-function baseline and the
resulting `pushNotificationAction` HTTP 404 have been retired.

## Reviewed deployment set

The local project contains these 16 functions:

- `advanceRound`
- `app-store-entitlement`
- `appleAuthBroker`
- `appleAuthCallback`
- `autoRegisterUser`
- `checkSubscription`
- `communityAction`
- `createCheckout`
- `deleteAccount`
- `gameRoomAction`
- `generateWordPack`
- `googleAuthCallback`
- `mobileAuthCallback`
- `pushNotificationAction`
- `stripe-entitlement-webhook`
- `wordPackAction`

`pushNotificationAction/function.jsonc` also defines the bounded notification
retry worker. The required production secret names have been checked without
reading, printing, or changing their values.

## Current validation

- all 259 Base44 Deno tests pass;
- every one of the 16 function entry points passes `deno check`;
- the required production secret names are present without exposing values;
- all required production entity schemas exist remotely;
- the iOS release bundle gate passes for version `1.0 (3)`;
- the fixed simulator build has no APNs registration loop;
- App Store notification request/status helper tests pass for Sandbox and
  Production environment selection; live Apple delivery remains a separate
  physical acceptance gate.

Repeat these tests before any future production deployment if the function tree
changes after this record is committed.

## Historical production command

The approved narrow deployment was run from the repository's `base44`
directory with:

```sh
npx base44 functions deploy
```

Do not rerun it merely to verify state. Any future deployment still requires a
fresh explicit production confirmation. Do not add `--force`, and do not expand
the operation to `base44 deploy`, `entities push`, `auth push`, `connectors
push`, or secrets changes without separate review and approval.

## Completed post-deploy verification

1. `npx base44 functions list` returns all 16 expected names.
2. All function entry points type-check and the complete backend test suite
   passes.
3. Build `1.0 (3)` is processed in App Store Connect and attached to version
   `1.0`.
4. The remaining physical-device acceptance work is tracked in
   `AppStoreAssets/TESTFLIGHT_ACCEPTANCE.md`, including Apple v2 delivery,
   purchase/restore, push, and Live Activity evidence.
