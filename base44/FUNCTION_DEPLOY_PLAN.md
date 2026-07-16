# Base44 function deploy plan

Target app: `69a0e57fa939f578082f8091` (`SpyClash`).

This plan is intentionally narrower than a full Base44 deployment. It does not
publish the site, push entity schemas, change auth configuration, modify
connectors, or set/delete secrets.

## Current remote baseline

The read-only production listing on July 16, 2026 returned five functions:

- `advanceRound`
- `autoRegisterUser`
- `checkSubscription`
- `createCheckout`
- `deleteAccount`

The running iOS simulator consequently receives HTTP 404 for
`pushNotificationAction` during APNs and Live Activity token registration.

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

## Validation before deploy

- all Base44 Deno tests pass;
- every function entry point passes `deno check`;
- all required production entity schemas exist remotely;
- the iOS release bundle gate passes for version `1.0 (3)`;
- the fixed simulator build has no APNs registration loop;
- the only current push/runtime blocker is the expected missing-function 404.

Repeat the tests immediately before the production operation if the function
tree changes after this plan is committed.

## Exact production command

Run from the repository's `base44` directory only after a fresh explicit
production confirmation:

```sh
npx base44 functions deploy
```

Do not add `--force`. Do not run `base44 deploy`, `entities push`, `auth push`,
`connectors push`, or any secrets command as part of this operation.

## Post-deploy verification

1. `npx base44 functions list` returns all 16 expected names.
2. Relaunch the iOS simulator and confirm that neither APNs nor Live Activity
   registration returns a missing-function 404.
3. Confirm there is no repeated registration/cancellation loop or sustained
   CPU spike.
4. Verify an authenticated device registration record is created/updated.
5. Run the reviewed App Store Server Notifications v2 test path separately;
   do not treat deployment alone as proof that Apple delivery works.
6. Only after backend verification, upload build `1.0 (3)` to App Store
   Connect under its separately confirmed production operation.
