# SpyClash 1.0.3 (187): authentication recovery and attempt ownership

Local candidate prepared from `4fce416b3acde02877d338100d8b8ba93ac61ea4`, branch `davidganzha/supabase-game-core`. The user-created reliability goal remains active. Production deployment, TestFlight delivery and repeated physical-device acceptance are separate pending gates.

## Incident evidence

On 18 October 2026 the user reported Apple sign-in failing with 503, then 403, then succeeding on the third attempt. Read-only Base44 logs show:

| UTC | Stage | Result |
| --- | --- | --- |
|22:51:54|Native Apple exchange|503, `temporarily_unavailable`|
|22:52:58–22:53:02|Second exchange, bootstrap, authorization, token and userinfo|Successful|
|22:53:04|`autoRegisterUserV2`|403|
|22:53:39–22:53:44|Third exchange through registration|Successful|

The 403 contains Base44's support-panel temporary-access denial. The deployed stack structurally matches a service-client `BillingIdentityLifecycle.filter` while asserting an Apple binding lease, after identity verification. All four pulled V2 runtime files match the prior reviewed candidate. Official local compilation and source mapping corroborate the call chain, but production minified bytes are unavailable: this is structural attribution, not an exact production source-map match. The particular lease assertion is not established.

The original 503 log discarded the internal credential/lifecycle subtype. Its precise cause cannot be recovered from that record. A separate Supabase `app-services` 503 at 22:50:19 has no proved causal connection to the Apple attempts.

## Server change

Only service-role entity `filter` reads receive bounded recovery. Eligible responses are the exact observed support-panel 403 message and 408/429/500/502/503/504. A read gets at most three attempts, with 150/400 ms delays; the two stores share four retries and a three-second recovery window per invocation. A recovered response arriving after the window is rejected. This is not cancellation or a hard timeout of an in-flight SDK request.

No write, invitation, whole registration handler, Apple authorization code, or provider exchange is replayed by this helper. Existing CAS reconciliation, deletion markers, owner checks and original binding tickets remain authoritative. Ordinary service 401/403 are classified as a service dependency failure without retry; caller identity 401/403 remain caller denials. A persistent storage problem cannot be reported as successful binding. An ambiguous write retains its existing ambiguous-write classification.

Registration and broker logs now record fixed stages and allowlisted dependency/credential/lifecycle codes. Raw SDK errors, authorization headers, tickets, emails, tokens, record contents and upstream messages are excluded. Public Apple OIDC errors keep the existing small response surface. The former native503 can therefore retain a useful private lifecycle code in future logs.

The new package contains exactly `appleAuthBroker` and `autoRegisterUserV2`. It preserves the freshly pulled lifecycle implementation; an unrelated constructor extension in the working tree is excluded. `autoRegisterUser`, other functions, entities, provider configuration, secrets and the website are not deployment targets. The shared credential helper's checked-in copies remain synchronized.

## Client change

Pending Supabase exchanges have ownership separate from the saved account generation. A superseded exchange cannot replace the current candidate or clean it up after a late response. Attempt checks cover provider registration, exchange and profile completion. Google uses the same ownership checks as native Apple. Email, OTP and stored-session upgrade also carry their original attempt guard, so a late first-stage response cannot start a replacement exchange.

Malformed successful bridge responses are 502 service-response failures. They no longer masquerade as a revoked 401 session and trigger deletion of valid saved credentials. Actual account mismatches and explicit revocation remain rejected.

Browserless Apple completion, Google callback policy and original Apple ticket validation are preserved. Build numbers advance together to 187; marketing version stays 1.0.3.

## Verification and remaining acceptance

- The unchanged 186 registration handler fails six new fault-injection steps; transient service reads return 403 instead of recovering, and a lost write acknowledgement followed by a transient read failure returns 503. The candidate passes all 25 V2 steps.
- The candidate broker/helper suite passes 82 tests plus 8 steps, including both provider callback policies, credential/deletion protections, strict retry bounds and diagnostic redaction. Runtime networking is denied. Real SDK module-loading tests require environment access; the V2 fixture suite denies environment and network access.
- A deterministic native baseline reproduced an older exchange replacing a newer ready candidate. The final Supabase build passes all 52 session/upgrade tests, including five new regressions and the existing Apple/Google binding-route checks. The final main native run passes 85 tests with zero failures; its one conditional HTTPS test passes separately in both fixture modes. Test transport is isolated per client so late logout cleanup cannot reach another test's authentication handler.
- Both frozen server functions pass official compiler checks individually and together; their actual packaged handler tests also pass (82 broker tests and 25 V2 steps). The unsigned device archive passes 18/18 checks, retains the production backend configuration, and contains no distribution signature or test resources. One test-only annotation changed during archiving; all captured production sources remained unchanged.
- All 773 existing server regression tests pass. The package refuses unexpected live-source drift and refuses to overwrite existing output.
- Both real HTTPS fixtures pass with build187 production code: redirects ending at `spyclash.com` and JavaScript completion ending at `app.base44.com`. Each makes exactly five local requests and zero requests to the token-bearing landing page. The temporary simulator, fixture processes and certificates were removed; existing device and macOS trust stores were untouched.
- GitHub checks include the authentication backend suite and both native authentication and Supabase session suites.

No production change has been made by this preparation. The frozen package contains only `appleAuthBroker` and `autoRegisterUserV2`, with manifest SHA-256 `28367f50e72064193593bb41b117b59b1f0ad41095bcd5bf596a091be6c6f1d0`. Its 19 runtime files match the reviewed source bytes. The app candidate is an unsigned 1.0.3 (187) device archive.

Next gates are a scoped GitHub checkpoint, explicit approval for deploying those two functions to the existing SpyClash Base44 app and signing/uploading 187 only to the existing David/Dima internal TestFlight group, deployed-source readback, and repeated/alternating Apple and Google sign-ins on physical iPhone. Cancellation, retry, app restart, correct existing-account continuity and two independent clients remain acceptance cases; local tests alone do not close the goal.
