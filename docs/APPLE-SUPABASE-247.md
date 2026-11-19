# Direct Apple sign-in — build 247

Build 246 could finish native Apple authorization and then reject the Base44 SSO redirect before obtaining an application session. Its diagnostic build also ran with a debugger, so that run does not establish release animation performance.

Build 247 sends the Apple identity token, one-use authorization code and nonce directly to the new Supabase `apple-session` function. It no longer starts the Base44 broker or hidden WebKit SSO for Apple login. Account acceptance precedes background room/realtime restoration. The device archive uses Swift `-O`; real-device acceptance must run without LLDB.

## Existing accounts

The existing Supabase Auth users have private imported mailboxes. Using Apple email to create or find users would risk duplicate accounts. The function instead verifies Apple JWKS, issuer, audience and nonce, redeems the authorization code, and resolves the verified subject through the same keyed digest used by the historical source. A private immutable registry maps that identity to the existing Supabase UUID. The server then issues and independently reads back a standard Supabase Auth session for that UUID. This is a custom Apple verification endpoint issuing Supabase sessions, not the built-in GoTrue Apple-provider flow.

The read-only pilot audit found two bound Apple owners with unique active, imported Supabase mappings. All three historical App Store account tokens must remain attached to their original owners. One historical entitlement was expired Sandbox; there were no active manual/Stripe grants or current-day quota records in that snapshot. Two pending AdMob attempts require a source transfer fence and faithful ledger import: old age alone does not invalidate a delayed signed callback.

The import compiler refuses ambiguous ownership, deleted/banned Auth users, inactive profiles or links, deletion intents, conflicting native identities, changed snapshots, and unsupported live rights. Source snapshots are private. Migration completion is recorded only after all ownership and rights checks succeed. New-account creation remains disabled for the initial two-account device pilot.

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
- Offline account/rights compiler: 21 unit tests and 6 actual local SQL tests passed. They verify preserved UUIDs, all historical billing aliases, reward state, idempotent replay and transaction rollback on conflicts. The real two-account plan remains deliberately non-executable until the source transfer receipt exists and matches the reviewed transfer IDs and fingerprints.
- Optimized archive, exact device profiles, main/widget entitlements and strict nested signatures verified. Version 1.0.4 (247); signing uses only the accessible development identity in the current login keychain.
- Release artifact gate fixtures: 81 passed. Source synchronization and release baseline checks passed; these do not certify App Store submission or a live server rollout.

Local private evidence is under `.local/apple-migration/`; simulator evidence is under `.local/apple-client-tests/`. Those files, account identifiers, SQL import values, private keys, configuration values and the dependency symlink are excluded from Git. The signed IPA has not yet been installed and the production changes have not been applied.

## Prepared production boundary

Target Supabase project: `bbkfsgnordtdiblgdzkg` (`spyclash-game-core`). Target Base44 app: `69a0e57fa939f578082f8091`.

Deployment packages are derived from downloaded live function versions, with only the reviewed authentication and required account-preservation changes applied. The current source tree contains unrelated changes relative to the live backend, so deploying its entire backend folder is unsafe. Use the isolated package manifest and verify live versions again immediately before activation.

The activation sequence requires a fresh explicit confirmation under `AGENTS.md`:

1. Verify the unchanged live source/mapping/rights baseline and package hashes.
2. Deploy the expiring administrator-only export helper; transfer the four existing Apple/HMAC settings encrypted to the fixed local RSA recipient. Decrypt only into a private directory outside the repository. Add a fresh, retained Apple grant encryption key; remove the export helper after readback. No user is asked for an unavailable old keychain password.
3. Apply the private schema and deploy the isolated native authentication, services, game-core, source-erasure and historical reward callback changes. Fence and import the exact historical reward rows under the source user lease before marking either account ready.
4. Import the two existing identities, all historical billing token aliases and complete source snapshots atomically, then enable the pilot configuration. Keep new signups off.
5. Read back ownership/registry/billing/transfer invariants. Install the already signed 247 on Ganzha without deleting its data; launch normally and ask the user to perform Apple sign-in once. Verify the same account UUID and restoration after relaunch.

Configuration names: `APPLE_SESSION_ENABLED`, `APPLE_SESSION_ENVIRONMENT=main`, `APPLE_NATIVE_CLIENT_ID=com.spyclash.ios`, `SPYCLASH_PSEUDONYM_KEY`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_P8_B64`, `APPLE_GRANT_ENCRYPTION_KEY`, `APP_NATIVE_APPLE_IAP_ENABLED=true`, `APPLE_NEW_ACCOUNTS_ENABLED=false`, `APPLE_MIGRATION_COVERAGE_VERIFIED=false`. The new public endpoint has gateway `verify_jwt=false` because it independently verifies Apple before issuing a Supabase session; protected application services retain their existing authentication checks.

Rollback must preserve issued Auth sessions, encrypted Apple grants, billing aliases and transferred reward ownership. Disabling new Apple exchanges does not authorize deleting those records or rolling the source reward fence back blindly. App Store submission, TestFlight promotion and public release are separate operations outside this approval.
