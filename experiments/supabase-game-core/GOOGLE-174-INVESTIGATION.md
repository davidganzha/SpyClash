# Google sign-in in main build 173: investigation and diagnostic candidate 174

Status on 2026-10-13: the failure is localized to the hosted web callback before native token acceptance. The exact cause on Ganzha is **not yet established**. Build 174 is a local source checkpoint for a diagnostic web change, not a claimed auth fix or a new TestFlight delivery.

## Evidence and boundaries

- The user selected their Google account and confirmed sign-in, then immediately saw the generic failure without pressing Refresh or Back on `spyclash.com`. That exact copy originates in `web-auth/src/lib/mobileAuthCallback.js`. A valid token or OAuth error changes the page to “Return to SpyClash”; a downstream native/Supabase error cannot create this HTML.
- The 20:55 UTC function invocations show Google callback/broker redirects followed by broker token POST 200 and userinfo GET 200. This fits a successful upstream OIDC exchange. Invocation status alone does not reveal the final redirect URL or prove native acceptance.
- A real Google sign-in through the same entry URL in Chrome completed at 21:02:50 UTC. The original return had exactly `auth_provider` and `access_token`, the provider matched Google and no fragment was present. The page produced a token-bearing `spyclash://auth` link. Only these boolean/key observations were retained. No token value, cookie or password was recorded. This was not an iPhone/native session acceptance.
- The actual shipped IPA 173 was independently checked: SHA-256 matches the delivery receipt, main bundle `com.spyclash.ios`, URL scheme `spyclash`, Google enabled and immutable main candidate configuration. The native session listens for that same scheme.
- An unsigned isolated iOS 26.5 Simulator probe used a real ephemeral `ASWebAuthenticationSession` with the current public callback and a **synthetic** value. It received the expected native callback in 2.067 seconds. The probe bypassed Google and the broker. It was removed afterwards so no additional `spyclash` handler remained.
- A page reload or second mount after URL cleanup reproduces the screenshot copy. This is a demonstrated mechanism, not evidence that the user refreshed the page. The old VM test's `location.href` getter incorrectly stayed at the original URL; the harness now models history changes.

Evidence: [sanitized investigation](evidence/full-app/build174/investigation.json), [real Simulator probe](evidence/full-app/build174/live-simulator-handoff-report.json), [published asset comparison](evidence/full-app/build174/baseline-assets-readback.json).

## Excluded changes

Custom SSO is intentional: canonical Base44 settings enable custom SSO and disable standard Google social login. Switching to the SDK's standard Google route would not match this setup. Removing the provider marker check is not supported as a causal fix by the successful real Chrome return. A global native `openURL` token fallback would weaken the current attempt ownership boundary. Neither change is included.

Safari privacy behavior is a plausible investigation direction, not a finding about this phone. WebKit documents that URL visibility to scripts can differ in private browsing: [Private Browsing 2.0](https://webkit.org/blog/15697/). Apple's callback delivery contract is documented under [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/).

## Prepared diagnostic

The failure page adds a fixed support code, navigation kind and capped mount marker. It never records or sends the URL, parameter values, token size, exceptions, cookies or credentials. No network, browser storage or SDK fallback is added. Successful handoff and every acceptance/rejection rule remain unchanged.

| Code | Meaning |
|---|---|
| SCG174-01 | URL outside the exact allowed form |
| SCG174-02 | Fragment delimiter present |
| SCG174-03 | Duplicate decoded parameter name |
| SCG174-04 | Query contains no parameters |
| SCG174-05 | Missing provider marker |
| SCG174-06 | Provider marker is not exactly Google |
| SCG174-07 | Missing token/error payload |
| SCG174-08 | Ambiguous token/error payload |
| SCG174-09 | Invalid token format/bounds |
| SCG174-10 | Invalid error format/bounds |
| SCG174-11 | Browser history cleanup failed |

`navigate`, `reload`, `back_forward` and `unknown` are the only permitted navigation labels. `m1` is the first mount in the module; `m2+` indicates a subsequent mount. A page reload resets the module counter and is separately identified by the browser navigation type. A separately evaluated module can also reset the counter; this diagnostic does not claim to identify every browser lifecycle event.

The production candidate is built on the retained **published** source, whose complete four static artifacts were fetched and compared byte for byte with the live site. A newly downloaded builder draft has different dependencies and is not substituted for that published baseline. The candidate keeps the ordinary website JavaScript, CSS and manifest byte-identical; only the callback entry and its filename in `index.html` change. See [candidate manifest](evidence/full-app/build174/site-candidate-manifest.json).

## Local validation

- 62/62 callback tests pass, including reload/remount and rejection privacy.
- Independent old/new differential: 56,086 URL inputs, 8,250 accepted and 47,836 rejected, no output differences or exceptions.
- 72 additional isolated mount checks pass: history cleanup first, no secret reflection, performance reads only the allowlisted navigation type, no navigation after cleanup failure.
- Vite production artifact builds successfully. Ordinary app JavaScript, CSS and manifest match the current public site byte for byte; `index.html` differs only in the callback entry filename. The final reviewed source hash equals the packaged source hash.
- Both project version declarations are synchronized to 174. Native executable code is unchanged, so this checkpoint does not make a new signed iPhone build.

[Independent parser review](evidence/full-app/build174/differential-callback-review.json). These checks do not establish the actual cause on Ganzha or constitute real Google-to-Supabase acceptance.

## Publication and next acceptance

The user explicitly approved publication of this exact callback diagnostic in the current chat. At approximately 21:34 UTC on 2026-10-13, CLI 0.0.56 `site deploy` published the prepared static artifact to the canonical app. No function, auth configuration, Supabase, TestFlight or App Store action was performed. The installed native build remains 173.

The canonical entry is now `index-goV7mmfZ.js`, with the expected SHA-256. All four served static assets matched the approved manifest; ordinary website assets remained byte-identical. Live browser checks showed `07 · navigate · m1` for missing payload, `04 · reload · m1` after cleanup/reload, and the expected safe native cancellation link for an OAuth error. Next: repeat Google sign-in on Ganzha using the installed build 173. [Deployment receipt](evidence/full-app/build174/deployment-postflight.json), [independent live check](evidence/full-app/build174/site-live-independent-readback.json), [browser checks](evidence/full-app/build174/live-browser-diagnostic-checks.json).

Collect the support code only if it fails. Do not request a full callback URL or HAR. Complete acceptance only when native token processing and the mapped Supabase account are both confirmed.

Do not run a general Base44 deployment: backend functions, entities, auth settings, secrets and connectors are outside this change. A subsequent actual auth fix must be based on the observed failure branch and reviewed independently.

## CLI side effect and cleanup

During investigation, `base44 eject --yes` was mistakenly treated as download-only based on its short help. Its implementation also created `SpyClash Copy` (`6ace9bf33f0bc793691a4ef4`) and began deploying schemas/functions into that new app. The process was stopped; five function deployments had completed, including an in-flight one. The copy was then moved through the supported UI to **Recently deleted**, with Restore available. It was not permanently deleted.

The original app ID was used only for download before CLI context switched to the new copy. Independent read-back found all 201 runtime files across the original 17 functions identical to the previous read-only snapshot; published static asset hashes also matched. This is not a row-by-row audit of all production data. [Cleanup evidence](evidence/full-app/build174/cli-eject-cleanup.json). Future source retrieval must use an explicitly verified read-only path; never use `eject --yes` for an audit.
