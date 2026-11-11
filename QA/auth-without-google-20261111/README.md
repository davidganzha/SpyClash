# Authentication options — build 233

The login and registration screens offer email/password, Apple, and (in the
current Supabase app configuration) Game Center. Google is no longer displayed.
Expired web sign-in messages in English, Russian, Ukrainian, and Spanish no
longer instruct the user to press the removed Google button.

This is a UI change. Existing authentication/session handling and provider
configuration remain compatible with stored sessions and older callbacks.
It does not migrate Apple or email authentication from Base44 to Supabase.

## Validation

- Signed Simulator build-for-testing succeeded with `SpyClash-Settings-UI`,
  `SupabaseDebug`, and `CODE_SIGNING_ALLOWED=YES`.
- Installed build 1.0.4 (233) using `scripts/install-ios-simulator-app.py` on
  Simulator `32694A40-883B-4650-89D4-699EC8D880A2`; signature, Keychain identity,
  and the installed bundle hash were verified without deleting app data.
- Both authentication entry UI tests passed: **2 passed, 0 failed, 0 skipped**.
  Result bundle: `/tmp/SpyClash-auth-without-google-233-auth-tests.xcresult`.
- To run the two entry tests against `SupabaseDebug`, set test-runner environment
  `SPYCLASH_EXPECT_GAME_CENTER=1` and select
  `SpyClashSettingsUITests/AuthenticationEntryUITests`. The standard `Debug`
  configuration omits Game Center and uses the default expectation of `false`.

The tests use UI preview mode, check the available providers, and navigate from
email to the login/registration password forms. They do not submit credentials,
start provider authentication, or prove real sign-in/session restoration.
No production backend/configuration changes, TestFlight upload, or App Store
release were performed.
