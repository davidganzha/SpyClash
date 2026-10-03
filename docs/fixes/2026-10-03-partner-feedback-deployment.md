# Partner feedback: production deployment — 3 October 2026

The user authorized the scoped backend deployment in this chat. Production was updated successfully from **13:18:26 to 13:18:42 UTC**.

- Canonical app: `69a0e57fa939f578082f8091`.
- Source checkpoint: `f48987bf977f90faf88f83ceee1f8068442339f3`, branch `davidganzha/partner-seven-fixes-162`; source version **1.0.2 (163)**.
- Named deployment order: **communityAction → notificationAction → gameRoomAction**, one successful command per function, using installed Base44 CLI 0.0.56.
- Runtime delta: **10 changed/added files**; complete target bundles contain **81 files** (21 + 10 + 50).
- No schema, secret, hosting, App Store/TestFlight, or device-installation operation was performed.

## Concurrent deployment and baseline preservation

A separate authorized chat was deploying the online intro duration from 8 to 3 seconds. This deployment waited for it to complete, then acquired the shared production mutation lock and pulled all 17 functions again. The final candidate was built on that fresh source. The exact `room-result-policy.ts` intro change was preserved; all other target baseline files matched `d327b0db08c8c45e5edfb492453da7b57b304c6d`. Unknown drift was rejected by the candidate builder.

The source checkpoint also fixes installed hosts that send the legacy `vote=false` payload: an explicit host return action resets the room for either boolean. Guest rejection, participant leases, match-generation and deadline checks remain in force. Older guest UIs may still display their previous vote button until the client update; the backend rejects that action.

## Verification

- Source tests: **546 passed**.
- Exact production candidate tests: **546 passed**. The validation-only intro boundary test was updated to 2.999/3.000 seconds to match the separately deployed duration. Its original 8-second expectation was the sole failure in the initial runtime test run; initial isolated fixture imports were also supplied from the fresh production pull. Neither test fixtures nor tests were deployed.
- All three entrypoints passed Deno type checks. All 81 runtime hashes and relative-import boundaries passed before deployment.
- A complete post-deployment pull matched **all 81 target files**, with the other **14 functions / 123 runtime files** byte-identical to the preflight baseline. Total: **17 functions / 204 runtime files**.
- Every function configuration matched preflight. The existing push retry automation retained its inactive state and 15-minute configuration.
- Read-only GET probes reached each deployed handler and returned its expected `405 Method not allowed` JSON response. No entity writes were used for these probes.
- Logs from the fixed deployment start boundary contained exactly those three expected GET/405 requests and no additional errors at verification time. This short window contained no authenticated gameplay traffic.
- The shared mutation lock was released after verification.

The preflight log sample contained earlier room-signal deadline errors and a room-no-longer-available 409. This deployment does not establish that those separate conditions are resolved.

[Before/candidate hashes](2026-10-03-partner-feedback-deployment.manifest.json) · [Postflight verification](2026-10-03-partner-feedback-deployment.verification.json)

## Evidence and recovery

Private local backup, exact candidate, validation fixtures, CLI outputs and verification scripts:
`/Users/davidganzha/Documents/SpyClash/.base44-cutover/partner-seven-20261003-3hdkeshs/`.

`preflight/` is the immediately preceding deployed baseline, including the 3-second intro. If a separately authorized rollback becomes necessary, restore `gameRoomAction` first, then the notification/community functions from that baseline. A code rollback does not restore invitations already resolved or notification sources already cancelled/deleted.

The seven-fix native client remains source/build work awaiting its own delivery. Real authenticated two-client acceptance, phone-to-phone invitation timing and permission recovery were not performed after this deployment.
