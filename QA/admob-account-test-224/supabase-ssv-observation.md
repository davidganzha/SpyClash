# Read-only SSV observation for the supervised 224 ad test

At 19:56:47 UTC, fresh Supabase readback confirmed gateway v2 and all 10 runtime files unchanged, app-services v19/JWTtrue unchanged, the global rewarded flag digest matching false, the owned unit digest matching the approved configuration, and no Supabase test allowlist present.

The parent initiated the normal Debug Base44 test flow at 20:02:32 UTC. The UI reported unavailable within two seconds and showed no ad. The parent then inspected the actual caught SDK error through LLDB: Account not approved yet. Its accompanying help URL was https://support.google.com/admob/answer/9905175#1.

Read-only gateway log queries returned zero callback records for both 20:02:30–20:03:00 and the final 20:02:30–20:04:30 UTC window. Only response timestamp, HTTP status and opaque request ID were requested; no raw URL, query, signature, custom data or tokens were output or saved. No user tables were queried. No Supabase production mutations occurred.

This proves that no callback was recorded in the observed window, consistent with rejection before ad display. It does not prove a real rewarded ad or an earned credit. The parent and Base44 agent own the independent account balance readback and test-access revocation evidence. Monitoring stopped after the final requested window; there were no automatic additional viewing attempts.
