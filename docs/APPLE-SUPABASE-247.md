# Direct Apple sign-in — build 247

Build 246 could finish native Apple authorization and then reject the Base44 SSO redirect before obtaining an application session. Its diagnostic build also ran with a debugger, so that run does not establish release animation performance.

Build 247 sends the Apple identity token, one-use authorization code and nonce directly to the new Supabase `apple-session` function. It no longer starts the Base44 broker or hidden WebKit SSO for Apple login. Account acceptance precedes background room/realtime restoration. The device archive uses Swift `-O`; real-device acceptance must run without LLDB.

## Existing accounts

The existing Supabase Auth users have private imported mailboxes. Using Apple email to create or find users would risk duplicate accounts. The function instead verifies Apple JWKS, issuer, audience and nonce, redeems the authorization code, and resolves the verified subject through the same keyed digest used by the historical source. A private immutable registry maps that identity to the existing Supabase UUID. The server then issues and independently reads back a standard Supabase Auth session for that UUID. This is a custom Apple verification endpoint issuing Supabase sessions, not the built-in GoTrue Apple-provider flow.

The pilot audit found two bound Apple owners with unique active, imported Supabase mappings. Activation preserved both existing Supabase Auth UUIDs and all three historical App Store billing aliases under their original owners. One historical entitlement was expired Sandbox; there were no active manual/Stripe grants or current-day quota records in that snapshot. Both pending AdMob attempts were fenced in the source and imported into the native reward ledger with their pending state preserved: old age alone does not invalidate a delayed signed callback.

The import compiler refuses ambiguous ownership, deleted/banned Auth users, inactive profiles or links, deletion intents, conflicting native identities, changed snapshots, and unsupported live rights. Source snapshots are private. The atomic import completed after the actual transfer receipt matched the reviewed transfer IDs and fingerprints. Readback confirmed both original Auth UUIDs, Apple/native readiness, owned primary identities, active profiles and matching source snapshots, with no deletion fences. New-account creation remains disabled for the initial two-account device pilot.

## Deletion and recovery

Apple refresh grants are encrypted and retained separately for revocation. Full deletion verifies both native cleanup and historical Base44 source erasure before returning `apple_account_deleted`. The historical erasure request uses a narrow server-signed proof; the new client does not retain a Base44 bearer for it. Existing owned Supabase sessions remain valid after migration.

An Apple code exchange with an unknown network outcome is recorded as unresolved. A fresh signed Apple request can still open the same account after the active issuer lease has ended; the old uncertain attempt does not permanently lock out login. Stale workers cannot publish a session, but can still durably capture a late Apple grant. Deletion remains pending until unknown issuance is reconciled: there is no blind code reuse, timeout that discards a possibly issued grant, or assumption that revoking a different token resolves it. Apple's [token revocation contract](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens) requires a refresh/access token and describes the associated session. This deletion edge case remains an operational pilot limitation. Automated tests are not proof that real Apple sign-in or revocation has completed.

AI generation may still use the existing server-owned Base44 relay. This change removes Base44 from Apple authentication; it does not move every application service away from Base44.

## Validation and artifacts

- Swift authentication/session tests: 86 passed, including 14 Apple-specific tests.
- Apple cryptography/replay tests: 10 passed; actual isolated local Supabase DB/Auth integration: 8 passed.
- Application services: 229 passed, plus 23 focused regression checks; full game core: 16 passed.
- Historical source deletion protocol: 48 passed.
- Encrypted secret export and offline recipient: 8 passed.
- Source reward transfer: 6 passed; callback gateway: 18 passed; actual local reward ledger integration: 4 passed, including delayed signed callbacks and duplicate-credit prevention.
- Offline account/rights compiler: 21 unit tests and 6 actual local SQL tests passed. They verify preserved UUIDs, all historical billing aliases, reward state, idempotent replay and transaction rollback on conflicts. The real two-account import subsequently executed successfully with the verified source transfer receipt.
- Optimized archive, exact device profiles, main/widget entitlements and strict nested signatures verified. Version 1.0.4 (247); signing uses only the accessible development identity in the current login keychain.
- Release artifact gate fixtures: 81 passed. Source synchronization and release baseline checks passed; these do not certify App Store submission or a live server rollout.

Local private evidence is under `.local/apple-migration/`; simulator evidence is under `.local/apple-client-tests/`. Those files, account identifiers, SQL import values, private keys, secret configuration values and the dependency symlink are excluded from Git. Production activation and installation completed; `devicectl` readback confirms version 1.0.4 (247) on the paired iPhone. Launch was blocked because the phone was locked. The next device check is a normal launch without LLDB after the user unlocks it. Real Apple sign-in, restoration after relaunch and animation performance have not yet been accepted on the device.

## Authorized activation — 19 November 2026

Target Supabase project: `bbkfsgnordtdiblgdzkg` (`spyclash-game-core`). Target Base44 app: `69a0e57fa939f578082f8091`.

The user explicitly approved this production package and installation of build 247 in the current chat. The authorized activation was complete by 17:34 UTC. Deployment used isolated packages derived from downloaded live function versions, with only the reviewed authentication and required account-preservation changes applied. Unrelated checkout backend changes were not deployed.

Completed operations and readback:

1. Applied both SQL migrations: `20261119110033_direct_apple_native_accounts.sql` and `20261119112119_apple_pending_reward_transfer.sql`.
2. Deployed and read back Supabase `app-services` v32, `full-game-core` v21, `rewarded-generation-ssv` v8 and `apple-session` v1 against the reviewed runtime package. Existing Game Center registry entries were preserved.
3. Deployed and verified the permanent Base44 `deleteAccountPublic` and `generationRewardAction` changes. The guarded schema update retained all 29 schemas, creating and deleting none; only the reviewed `GenerationReward` transfer changes were applied.
4. Transferred the four existing Apple/HMAC settings through the encrypted export, retained them in a private directory outside Git, and added the Apple grant encryption key and pilot flags. All 11 supplied settings passed digest readback; unrelated existing settings remained unchanged. The enabled Apple endpoint returned `400 invalid_request` for an empty request rather than the disabled response. This is a bootstrap check, not a real Apple login.
5. Fenced the exact two historical reward rows, then executed the final atomic account/rights SQL import. Readback confirmed two preserved Auth identities and native-ready profiles, matching snapshots, three billing aliases and two reward aliases/ledgers. Source Apple bindings and unrelated rights remained unchanged. The executed SQL digest and actual transfer receipt are retained privately.
6. Removed both temporary administrative helpers after their respective export/import acknowledgements and verified their absence. The permanent Base44 functions still matched the approved package.
7. Installed the signed 247 and verified version 1.0.4 (247) through `devicectl`. Device launch remains pending an unlocked phone; no successful Apple interaction or performance acceptance is claimed.

Private activation receipts include `.local/apple-migration/supabase-activation-receipt.json`, `.local/apple-migration/activation/base44-activation-summary.json`, `.local/apple-migration/activation/source-transfer-scope-verification.json` and `.local/apple-migration/activation-and-device-status.json`. They retain operation timestamps, package/import digests and readback evidence without publishing account data or secrets in this document. Historical source-erasure capability was checked without deleting an account; actual Apple revocation remains untested.

Applied configuration names: `APPLE_SESSION_ENABLED=true`, `APPLE_SESSION_ENVIRONMENT=main`, `APPLE_NATIVE_CLIENT_ID=com.spyclash.ios`, `SPYCLASH_PSEUDONYM_KEY`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_P8_B64`, `APPLE_GRANT_ENCRYPTION_KEY`, `APP_NATIVE_APPLE_IAP_ENABLED=true`, `APPLE_NEW_ACCOUNTS_ENABLED=false`, `APPLE_MIGRATION_COVERAGE_VERIFIED=false`. The new public endpoint has gateway `verify_jwt=false` because it independently verifies Apple before issuing a Supabase session; protected application services retain their existing authentication checks.

Rollback must preserve issued Auth sessions, encrypted Apple grants, billing aliases and transferred reward ownership. Disabling new Apple exchanges does not authorize deleting those records or rolling the source reward fence back blindly. App Store submission, TestFlight promotion and public release are separate operations outside this approval.
