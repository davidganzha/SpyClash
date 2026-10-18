# SpyClash 1.0.3 (185): invisible Apple completion repair

18 October 2026. Based on build 184 delivery checkpoint `776621ff`, branch `davidganzha/supabase-game-core`.

## Report and observed boundary

The user reported bare `SCA177-H03` on a physical iPhone running TestFlight 184 at about 00:58 London time. Google works on that phone. The separate unsigned-Simulator Keychain problem was repaired by rebuilding and installing build 184 with Simulator ad-hoc signing; that repair did not modify the iPhone artifact.

Read-only broker logs for 17 October 23:58 UTC show native exchange POST 200, bootstrap GET 302, authorize GET 302, token POST 200 and userinfo GET 200. The native exchange and broker processing completed. These statuses do not identify the final Base44 navigation, frame, response MIME type or method. Build 184 collapsed multiple WebKit rejections into the same bare H03, so the exact branch on this phone remains unknown.

The user explicitly requires no visible browser after the native Apple sheet. Build 185 preserves that behavior and adds no browser fallback.

## Change

An incidental child-frame navigation used to cancel the entire main Apple attempt with H03. Two actual-WebKit regressions reproduced this against the unchanged build 184 implementation. The completion session now cancels an auxiliary frame without terminating the independently owned main attempt. A child-frame callback cannot complete authentication, including when it targets the top frame or a new window.

Main-document popups, downloads, absent URLs, unexpected methods, forbidden documents and unsupported MIME types now have distinct fixed failure categories H30–H35. Rejections retain the existing bounded structural diagnostic suffix; URLs, header values, cookies, credential values and arbitrary response text are not retained. Callback validation, destination allowlists, native account binding and cancellation ownership remain in force.

The WKWebView still uses an isolated, nonpersistent store and is never attached to a window. The Google flow, account mapping, backend, website and runtime configuration are unchanged. Both project build-number definitions advance to 185; marketing version remains 1.0.3.

## Alternatives and remaining uncertainty

The public [Base44 auth SDK](https://docs.base44.com/developers/references/sdk/docs/interfaces/auth) does not document a native Apple-credential-to-Base44-session exchange. Its [SSO access-token method](https://docs.base44.com/developers/references/sdk/docs/interfaces/sso) retrieves the external provider token, not a new Base44 application session. A [direct Supabase Apple sign-in](https://supabase.com/docs/reference/swift/auth-signinwithidtoken) is possible as a separate architecture, but the current hybrid account and billing routes depend on the existing Base44 identity binding. Changing that identity path is not a safe drop-in repair for this report.

The known broker callback destination and the observed initial SSO redirects match the current allowlist. No captured successful terminal response justifies widening it. The iframe defect is reproduced and fixed locally; whether it caused this particular physical-iPhone failure requires a fresh attempt with build 185.

## Verification scope

- The final focused authentication run passed **69/69** tests: native Apple handoff, 14 actual-WebKit tests, Apple request ownership, shared authentication flows, and coordinator cancellation/deadlines. All 13 selected source hashes matched after the run. This is Simulator evidence, not physical provider acceptance.
- Two actual-WebKit regressions failed against the unchanged build 184 implementation and passed after the repair: incidental child frames and child callbacks no longer terminate the main attempt, and a subsequent valid main callback completes once.
- The final WebKit suite exercises the real browser engine without presenting a view. It covers isolated cookies, callback interception, ownership/cancellation, rejection of foreign or interactive navigation, bounded H30/H33/H34 diagnostics, and expiry cleanup. The deadline fixture uses injected time after document readiness, avoiding a cold-engine-startup race.
- Initial new fixtures that subclassed WebKit wrapper objects crashed and were removed. Replacement child-to-top and simulated-MIME fixtures did not generate the required navigation events and were also removed from the claimed coverage. The source-frame guard and MIME branch are reviewed code; these exact runtime cases remain unproven. None of these fixtures changes production behavior.
- The final unsigned `SupabaseRelease` archive passed 13 checks, including main/widget 1.0.3 (185), unchanged backend configuration, source hashes, and absence of a distribution signature or test bundles. Twelve selected production/control files matched the captured source before and after the final archive.

Sanitized receipts are under `evidence/full-app/build185/`. Local result bundles and the unsigned archive remain under ignored `.local/apple185-no-browser/`.

## Delivery boundary

The code checkpoint was a local repair and diagnostic candidate. After separate explicit approval in this chat, build 185 was signed, uploaded and verified as available in TestFlight Internal Only to David and Dima. See [RELEASE-185.md](RELEASE-185.md) for the exact artifact and final audience verification.

This delivery does not establish successful real Apple sign-in, prior-account continuity or perceived speed on a physical iPhone. No backend or website deployment, App Review submission or public App Store release was performed.

The subsequent physical-iPhone test at approximately 01:32 London time failed with `SCA177-H34-r6-s0-cN-uOT-q12-pN-fN`. Build 185 did not restore Apple sign-in. The next local candidate and its changed acceptance boundary are documented in [APPLE-SIGN-IN-186.md](APPLE-SIGN-IN-186.md).
