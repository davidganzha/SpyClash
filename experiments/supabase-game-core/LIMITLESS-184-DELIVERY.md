# LIMITLESS server repair and internal TestFlight 184

Delivered on 17 October 2026 with explicit approval in the current chat. SpyClash **1.0.3 (184)** is processed and available in the existing **LIMITLESS Internal QA** group to David and Dima only. App Store Connect confirmed `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, and external testing `NOT_APPLICABLE` at 22:11:30 UTC.

## Delivered artifact

- Source: `c56719c87471e2cb90385adef57e373b8131be59` on `davidganzha/supabase-game-core`.
- App: `com.spyclash.ios`; App Store Connect app `6793534085`.
- Build ID: `15e97a22-58e7-4e85-953a-c8c520d5b37d`.
- IPA SHA-256: `93e90e6d999bbc5f3c6986b10ee0bc7b598804fa2e4638ca6a54bbf009d0a3f9` (12,768,934 bytes).
- Both app and widget are 1.0.3 (184). Export explicitly used `testFlightInternalTestingOnly=true` and `manageAppVersionAndBuildNumber=false`.
- Source verification: 11/11; signed archive: 17/17; independent IPA audit: 19/19; final portal audit: 16/16. Apple validation and upload exited successfully. Only six existing signing settings in the isolated packaging copy differed from committed source.
- [GitHub regression run](https://github.com/davidganzha/SpyClash/actions/runs/39072946080): both jobs passed, including all 88 client tests. The compiler regression from 183 was corrected in test infrastructure.

The native Apple completion implementation matches build 182. The weekly LIMITLESS product remains `com.spyclash.ios.limitless.weekly`. This release includes the bounded transaction-delivery retries documented in [LIMITLESS-183.md](LIMITLESS-183.md).

## Server deployment

Only Supabase project `bbkfsgnordtdiblgdzkg`, Edge Function `app-services`, was deployed, advancing v9 to **v10** at 22:04:30 UTC. The approved package preserves an explicit temporary Apple account-binding-busy response so the client can retry delivery of the same transaction. This does not retry a purchase or bypass entitlement verification.

All 55 deployed source files match the approved package; only `app-services/legacy-billing.ts` changed (+7 lines). JWT verification, import map, entrypoint and the other 54 files were retained. The deployed bundle SHA-256 is `f08c9441ab93e825a8a574b5efb2f7a0325bc4647e44f108ed12a0b7b7046706`. Missing and invalid authorization both returned 401. No Base44 function, database schema, secret, payment product or website was changed during this delivery.

## Scope of verification

The earlier physical build 182 Restore, access refresh and cold-relaunch checks succeeded with the existing account and subscription, before this server deployment. A new first purchase and a physical Restore/Apple sign-in in build 184 have **not** been performed. The temporary contention branch is supported by the focused predeploy regressions and exact deployed-source verification; no real postdeploy contention event was induced. The five opt-in local StoreKit integration tests remain unproven because of the documented simulator StoreKit limitation.

Final App Store Connect readback confirmed exactly two effective testers, no individual assignments, no other group receiving 184, and unchanged group membership, existing build assignments and public App Store versions. No App Review submission or public release was performed.

The redacted release receipt is [evidence/full-app/build184/limitless-delivery.json](evidence/full-app/build184/limitless-delivery.json). Full local source, archive, IPA, logs, portal readbacks and backend readbacks are retained under ignored `.local/release184/`; the exact v9 rollback package remains under `.local/limitless183/deploy/`.
