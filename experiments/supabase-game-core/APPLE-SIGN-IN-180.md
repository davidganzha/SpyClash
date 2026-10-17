# Apple sign-in repair, build 180

Status: local implementation, build, and validation passed. No Apple production
deployment, signed build, TestFlight upload, or successful physical sign-in is
claimed by this checkpoint. The separate LIMITLESS route repair is live; see
[LIMITLESS-V2-REPAIR.md](LIMITLESS-V2-REPAIR.md).

## Observed failure

The user repeated Apple sign-in on installed build 176 on 17 October 2026 and
reported the same generic invalid-response toast. The screenshot clock is
19:58 Europe/London. The matching sanitized server trace at 18:58:30–33 UTC
contains POST 200, GET 302, GET 302, POST 200, GET 200, consistent with native
exchange, bootstrap, authorization, token exchange, and user-info completion.
The preceding 18:55 attempt also has successful broker responses. The pending
credential metadata also records a successful native exchange. No provider
credential, account email, access token, or full callback URL is included in
the tracked evidence.

This narrows the remaining failure to completion after the broker and before
the application accepts the Base44 session. It does not reveal the exact
terminal response seen by build 176. HTML/JavaScript completion and other
browser-owned session behavior remain possible explanations, not a captured
root-cause response. Negative protocol probes and Foundation cookie fixtures
did not reproduce a cookie-forwarding defect.

## Implementation

The native Apple authorization and server-side credential exchange remain the
first steps. The resulting validated, short-lived bootstrap URL now opens in
the application's owned `ASWebAuthenticationSession`. The session completes
through a dedicated Apple callback page and a strict Apple-marked custom URL.
There is no second native exchange or fallback to the old silent URLSession
handoff. The browser is bounded by 90 seconds and the current authentication
attempt/session generation. Cancellation stays silent, and a late callback
cannot overwrite a replacement account.

The callback page owns only
`https://spyclash.com/MobileAppleAuthCallback.html`. It clears credential-bearing
URL data before rendering, rejects malformed/duplicate/mixed parameters, and
forwards only a token or a safe fixed error to `spyclash://auth`. It does not
load the normal website SDK, storage, analytics, or network bootstrap. The
existing Google parser and normal application bundle are preserved.

The original `autoRegisterUser` runtime separately ignores the Apple binding
ticket. An actual-handler regression fixture demonstrates that an invalid
ticket can receive success while the credential remains pending. The new
single-function `autoRegisterUserV2` package contains the four exact previously
reviewed modern runtime files. It validates the ticket against verified
identity and account ownership and completes binding before returning success.
The native app selects V2 only when carrying an Apple binding ticket, and
requires explicit success with a returned user before accepting the session.
Google keeps its existing registration behavior.

Apple documents browser authentication and the app-owned completion callback in
[ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).
This supports the selected transport; it is not evidence that this particular
phone attempt now succeeds.

## Production scope awaiting approval

1. Canonical Base44 SpyClash app `69a0e57fa939f578082f8091`: add only
   `autoRegisterUserV2` by named deployment, verify live method/auth responses,
   and verify all existing function sources remain unchanged.
2. Publish the frozen site-only callback artifact to `spyclash.com`, preserving
   the published ordinary website JavaScript, CSS, manifest, and Google flow.

No broker/provider configuration, secret, Supabase function, payment setting,
App Store Connect action, or TestFlight delivery belongs to this proposal.
The native change requires a later approved device build. Publishing these
dependencies alone does not replace build 176's native handoff.

## Prepared artifacts and verification

- Native version: `180` in `project.yml` and every project build configuration;
  marketing version remains `1.0.3`.
- 55 focused native authentication tests passed. After the final response guard
  and stale-error fix, the 28 affected tests passed again. Three direct tests of
  the conditional Supabase provider transport passed, covering V2 success,
  malformed/legacy response rejection, and unchanged Google registration.
- The final unsigned `SupabaseRelease` build passed against the frozen source.
- 104 callback tests passed, including all 66 existing Google checks.
- 13 cases also passed in macOS WebKit using the actual frozen Vite entry and
  HTML guards in synthetic HTTPS documents. Native navigation was intercepted;
  network was blocked. This verifies rendered callback execution, not a real
  provider session or physical-device acceptance.
- 17 actual-handler backend steps, the real SDK typecheck, and a locally
  compiled Worker method/auth contract passed. Independent source review found
  no blocking issue.
- Backend deployment directory: `.local/apple180-browser/autoregister-v2`.
  Generated manifest SHA256:
  `1d9b539f4b76af3a2a1b5f190709a40bf9904d572e85db87ce7aa4cd54680ef5`.
  Reproduce with `scripts/package-auto-register-v2.py`.
- Site deployment directory: `.local/apple180-browser/site-deploy`; rollback:
  `.local/apple180-browser/site-rollback`. Manifest SHA256:
  `fe54c9b1f5abc3474e424dc678f70a886e887581c068748ecf16b9305d79c277`.
  Entry asset: `assets/index-B5iDK17o.js`. The ordinary app JS, CSS, and manifest
  match the five-file published-175 baseline checked live before packaging.
- Sanitized manifests, test receipts, and timestamp/status-only broker traces
  are in `evidence/full-app/build180`. Detailed local result bundles remain in
  `.local/apple180-browser`.

Immediately before deployment, recheck the published site baseline and existing
18-function inventory. Deploy only the named V2 function and frozen site
package. Afterward, recheck the unchanged existing function sources and public
V2 GET405/unauthenticated POST401; verify all five published static hashes and
the Apple/Google callback routes. Leave V2 unreferenced if native delivery is
deferred. The site rollback package restores the exact prior published assets.

## Acceptance still required

A physical Apple authorization must return to the app, bind the verified
Apple credential, establish the application session, and show the correct
profile. Cancellation must also leave the current account unchanged. Local
fixtures, browser rendering, and an unsigned compile are separate from this
acceptance. The user postponed TestFlight delivery until the repair is ready.
