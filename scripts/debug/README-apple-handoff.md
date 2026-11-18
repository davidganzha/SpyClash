# Apple completion navigation inspection

This helper observes a paused, user-owned **Debug** attempt. It does not sign in,
install an app, resume the process, change navigation policy, read browser
cookies/storage, or make a network request. Do not replace the installed
TestFlight build just to run it. A real device sign-in remains a separate,
coordinated confirmation; the helper alone does not verify sign-in recovery.

1. Use a development-signed candidate with Swift debug symbols and optimizations
   disabled. In Xcode/LLDB, break in
   `AppleSessionCompletionSession.webView(_:decidePolicyFor:decisionHandler:)`
   taking `WKNavigationAction`, immediately before `permitsSessionDocument(url)`.
2. Import the helper using its absolute path:

   ```text
   command script import /absolute/worktree/scripts/debug/apple_handoff_envelope.py
   ```

3. When the owned attempt stops on its sixth main-document navigation, run:

   ```text
   apple-handoff-envelope
   ```

   Inspect only its JSON output. Do not run `po navigationAction`, `po url`, or
   print requests, headers or cookies. The helper never displays query values,
   fragments, unknown query names, unknown path segments, or evaluation errors.
   It prints trusted host, a closed-vocabulary path shape, a path digest, known
   query-name labels and bounded counts. A digest is only a correlation aid;
   it does not prove an endpoint's contract or authorize navigation.

4. Resume with the existing policy unchanged. Correlate the attempt time with
   Base44 Monitoring `app.auth.login` and the five broker invocations. Resolve
   the observed route against an official contract before proposing any route
   or code-exchange change. If a path segment remains `<other>`, establish it
   from that contract; do not expose the raw URL to fill the gap.

The current known boundary is a successful server SSO followed by
`H34-r6-s0-cN-uOT-q10-pN-fN`: the rejected navigation has no `access_token`.
SDK 0.8.63 still consumes `access_token`; neither its auth module nor the public
Base44 OpenAPI exposes an app-login authorization-code exchange. Cookie-only
authentication documented for `auth.me()` does not provide a native bearer
session or replace the existing native Apple identity binding.

## TestFlight support code

No debugger is needed to collect the bounded shape added in build 246. The
existing alert's **Copy support code** button includes `-d<route>-k<hex mask>`
only for a rejected trusted-host landing without `access_token`. Navigation
permissions, account verification and session saving stay unchanged.

Route labels: `RT` = root, `HM` = `/home`, `LI` = `/login`, `RG` = `/register`,
`SS` = another canonical-app `/auth/sso/` path, `PA` = `/api/apps/auth/` path,
`LB` = fixed legacy mobile callback, `GC` = Google mobile callback, `EC` =
`/cdn-cgi/` path, `OT` = other. Prefix categories do not expose the remaining
path. They are observations, not proof that an endpoint is supported or safe.

The hex mask records presence of fixed names only:

| Bit | Query name |
| --- | --- |
| `1` | `code` |
| `2` | `auth_code` |
| `4` | `authorization_code` |
| `8` | `token` |
| `10` | `from_url` |
| `20` | `redirect_uri` |
| `40` | `returnTo` |
| `80` | `is_new_user` |
| `100` | `session_id` |
| `200` | `app_id` |

One coordinated real attempt plus its copied support code can distinguish a
code-bearing return from an unexpected login, CDN or legacy callback route.
For example, `dPA-k11` means a platform-auth prefix with `code` and `from_url`;
it does not reveal their values or imply a working code-exchange API. `dOT-k0`
still needs a documented endpoint or a controlled local debugger observation.
