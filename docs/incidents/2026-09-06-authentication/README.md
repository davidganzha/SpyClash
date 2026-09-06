# Authentication audit and recovery — build 145

Prepared on 2026-09-06 from `davidganzha/partner-bugfix-143`, following the Google browser sheet showing `invalid_state` during build 144 testing. Version is `1.0.1 (145)` in both project definitions.

## Findings and changes

| Confirmed code problem | Resulting behavior |
| --- | --- |
| Google browser authentication had no lifetime bound; an expired server transaction could leave a sheet open indefinitely. Cancellation and late framework completion did not have independent ownership. | A coordinator owns each attempt, completes it once, closes it after five minutes, handles cancellation without relying on a framework callback, and rejects callbacks arriving after the deadline or from a superseded attempt. The app presents a localized retry message. |
| Login and profile synchronization could install credentials after logout, or clear an existing valid token when the candidate profile request failed. | Attempt IDs and session generations fence late results. Provider credentials are verified before replacing the current session. A temporary profile failure preserves existing credentials. Email login commits its token only after the owner check. |
| Cold-start restore retained a token after a temporary failure, but foreground recovery required an already loaded user. Concurrent restore responses could also affect a replacement account. | Restore is single-flight, retries on activation without a user profile, and ignores stale success/401 responses. Logout and explicit sign-in supersede stored-token bootstrap. A current confirmed 401 still clears rejected credentials. |
| Apple authorization callbacks and reveal animations could outlive their request and change a later attempt. | The rendered Apple button captures a request ID in both framework callbacks. Old cancellations, exchanges and reveal continuations cannot complete the replacement attempt. |
| OTP verification made an obsolete unauthenticated profile-registration call before checking the code. Callback parsing accepted insufficiently constrained URLs. | OTP uses the verification endpoint directly. Google callback parsing validates the exact app route, rejects duplicate/ambiguous fields and malformed tokens, and does not display untrusted error descriptions. |
| Google state rejection returned raw JSON even to an interactive browser. Expiry and other state failures shared one telemetry reason. | The prepared backend candidate returns a localized recovery page to HTML browser GETs and distinguishes actual JWT expiry in telemetry. JSON API responses and state/signature/cookie checks are preserved. See [the exact staged backend scope](backend-staging.md). |

The screenshot proves rejection of that Google transaction, not a general Google/Apple outage. Read-only logs showed starts at 07:55, 08:31 and 08:32 UTC, then rejected callbacks at 14:28:46/49 UTC without a newer observed start. The broker state lifetime is 300 seconds with five seconds of verification tolerance. These times support a stale-window explanation, but the old `state_jwt_invalid` telemetry alone cannot prove expiry rather than another validation failure. The preceding build 144 production deployment changed `gameRoomAction` and `generateWordPack`; the freshly pulled authentication runtime matched the earlier postflight baseline.

## Verification

- Full iOS suite: **491 passed, 0 failed, 0 skipped**, including 35 new tests covering coordinator completion/cancellation/deadlines, session restoration, credential ownership and Apple request ownership. Tests inject token storage and simulated network responses; they do not need real account credentials.
- Backend authentication suite: **65 passed, 0 failed**. Actual handlers are tested with signed expired and invalid-signature state, cookie cleanup, response negotiation and fixed retry links. Both staged runtime entry points pass Deno type checks.
- The isolated deployment candidate has exactly two functions and three runtime file changes. Baseline/candidate guards, exact patch reconstruction and six negative guard checks pass. New tests remain outside the deployment directory.
- Debug Simulator and signed device builds succeeded. Strict deep code-signature verification passed for the device artifact. The original macOS keychain search list was restored after signing.
- `git diff --check` passed before the checkpoint.

Full iOS result bundle:

```text
/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-09-06T14-53-11-972Z_pid23192_31cc6c08.xcresult
```

## Installed clients and remaining acceptance

- Dedicated Simulator: **SpyClash Auth — iPhone 17**, iOS 26.5, ID `21688882-58EC-4842-87EB-F20E7CA29753`. Build 145 launched; screenshot confirmed the welcome/sign-in entry screen. Semantic UI inspection failed in the simulator tooling, so no automated taps or provider sign-in success are claimed.
- Physical **Ganzha**, iPhone 17 Pro Max: build **1.0.1 (145)** installed and confirmed by device app metadata. Launch was rejected because the phone was locked. Installation does not prove a running build or a successful sign-in.
- Signed device artifact: `/tmp/spyclash-144-ganzha-device/Build/Products/Debug-iphoneos/SpyClash.app`. The reused directory name contains 144; the verified app metadata is 145.
- Device build/install/launch evidence: `/tmp/spyclash-145-ganzha-device-build.log`, `/tmp/spyclash-145-ganzha-install.json`, `/tmp/spyclash-145-ganzha-launch.json` and `/tmp/spyclash-145-ganzha-apps.json`.

Fresh Google, Apple and email/OTP login with real accounts still require interactive acceptance. The two-client game check also remains open. After unlocking the phone, launch the installed build and use separate accounts on the phone and dedicated Simulator; verify fresh login, cancel/retry, expired-window recovery and foreground restoration before claiming end-to-end completion.

**No authentication backend deployment, production configuration change, TestFlight upload or App Store action was performed.** The reviewed candidate for `appleAuthBroker` and `googleAuthCallback` requires fresh approval for those exact functions, followed by the documented drift checks and postflight verification. The earlier approval for game-room/generation functions does not cover this authentication deployment.
