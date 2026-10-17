# SpyClash 1.0.3 (182): Apple sign-in without a visible browser

17 October 2026. Based on the shipped 181 source and release checkpoint `d198f288a58fd81ea0b3df902ec9b6be1de0fd40`, branch `davidganzha/supabase-game-core`.

## User-visible change

Build 181 opened an `ASWebAuthenticationSession` after the native Apple authorization sheet had completed. The supplied recording shows that browser moving between SpyClash and Base44 before returning to the native animation and home. This was the session-completion transport introduced in 180, not another required Face ID check.

Build 182 retains the native Apple sheet and completes the already-authorized session in a separate, nonpersistent `WKWebView` that is never attached to a window or presented. There is no Apple-path browser fallback. The native animation remains visible while the session and profile are verified. Its four-second minimum has been removed; verified success finishes the mark promptly, then follows the existing home reveal. Reduced Motion skips the success zoom and electricity.

## Account and failure handling

The original native credential exchange, binding ticket, `autoRegisterUserV2` ownership verification and Base44-to-Supabase account mapping remain in place. The patch does not create a new identity provider or substitute email matching. Google continues to use its existing coordinator and presentation behavior.

The internal completion session permits only the fixed bootstrap and Base44 SSO routes, accepts only strictly validated Apple-marked callbacks, and intercepts a callback before loading its page. Provider login pages, foreign destinations, forms, subframes, popups, dialogs and downloads fail closed. Each attempt owns its data store, cancellation, deadline and cleanup; stale attempts cannot install a session. Tokens are not logged or written into diagnostic artifacts.

This supports both HTTP navigation and JavaScript-driven completion. The precise cause of the old 176 invalid-response failure was not captured; this patch does not claim that HTML alone was proven to cause it.

## Verification

- 67/67 focused Simulator tests passed: Apple request ownership, native callback policy, authentication flows, coordinator cancellation/deadlines, and 12 actual-WebKit tests. The WebKit fixtures cover JavaScript and HTTPS callback interception, blocked interactive/foreign navigation, cookie isolation, cleanup and the eight exact Objective-C delegate selectors. Test-only network proxying blocks outbound fixture navigation.
- The first WebKit run exposed Swift 6 optional-delegate signature mismatches. The signatures were corrected to match the installed SDK before the successful run; the selector assertions now guard this regression.
- An unsigned `SpyClash-Supabase-Main-Candidate` archive in `SupabaseRelease` passed 16/16 artifact checks. Main app and widget are both 1.0.3 (182). All 1,275 captured source files matched before and after compilation. Runtime configuration remains byte-identical to 181; no signing step ran.
- The debug Apple animation preview was built, installed, launched and visually inspected in Simulator through assembly, success and home. The preview uses synthetic account data and its own fixed timing; it is not a real Apple login or a measurement of production sign-in speed.

Receipts: `evidence/full-app/build182/`. The unsigned archive, full source hash manifest and preview recording are preserved under ignored `.local/apple182/`.

## Delivery boundary

After the user separately approved delivery, 1.0.3 (182) was signed, uploaded and verified as available in TestFlight Internal Only for the existing private David/Dima group. See `RELEASE-182.md` and the final App Store Connect receipt. No server, website or production configuration changes were made during this release; the live 179/180 Apple and LIMITLESS fixes and 181 social deployment are retained.

Physical Face ID, real prior-account continuity and perceived speed must be accepted on the updated iPhone build; Simulator fixtures and TestFlight availability do not establish these results. No external testing or App Store submission was performed.
