# SpyClash 1.0.3 (181) — internal delivery

17 October 2026. Source: `eb1b11cd34ff5d3549b41fda9795129d9cec9f9a`, branch `davidganzha/supabase-game-core`. The user explicitly approved checking build 181, applying the friends/invitations server changes, and distributing Main SpyClash to David and Dima through TestFlight Internal Only.

## Server deployment

Supabase project `bbkfsgnordtdiblgdzkg`, `app-services`, advanced from version 8 to version 9. A fresh live 55-file snapshot was frozen with rollback; only `community.ts` and `profile.ts` received the 181 commit delta. Readback matched all 55 candidate files. The other 53 files, including the LIMITLESS `checkSubscriptionV2` bridge, remained byte-identical. JWT verification and import map remained enabled; no schema, secret or configuration change was made.

The frozen package passed typecheck and 16 focused integration checks against actual local Auth, PostgreSQL and Realtime, including recipient isolation and reconnect. Hosted signal-table RLS, publication and required indexes were checked read-only. Live unauthenticated and invalid-token requests were rejected; a version 9 runtime boot was observed with no errors in the bounded log sample. Authenticated production social operations and two-phone delivery remain a device acceptance step.

## Signed build and Apple delivery

The Main candidate scheme compiled and archived in `SupabaseRelease` using the existing distribution identity. Both main app and widget are 1.0.3 (181). Export set `testFlightInternalTestingOnly=true` and preserved the build number. The signed IPA passed identity, signatures, entitlements, committed configuration and credential-exclusion audits.

IPA SHA-256: `1c9669febc927773483508038290c4776b9ba8964357e5970f84e5b015112dd3` (12,699,843 bytes).

Apple validation and upload succeeded without errors. Delivery/build ID: `19cf0e7c-b3ea-4649-b8ef-875a46a5ce1f`. Independent App Store Connect readback at 19:49:50 UTC confirmed `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, and external state `NOT_APPLICABLE`.

The build was assigned only to the existing private group `LIMITLESS Internal QA`, with David Ganzha and Dima Ianushevych as its only members. All 15 final checks passed: no individual assignments or automatic all-build access, unchanged group membership/controls, unchanged prior build assignments, and unchanged App Store versions and attached builds. No App Store submission, external testing or public distribution was performed.

## Apple Sign In and LIMITLESS

The181 source includes the Apple 180 browser-completion and verified-profile-binding changes unchanged. All five published Apple 180 static asset hashes and both callback routes still match the deployed package. This release preserves the already-deployed `autoRegisterUserV2` and `checkSubscriptionV2` work.

Current local unauthenticated Base44 probes were blocked by Cloudflare 1010 (`browser_signature_banned`) before reaching application gates; those probes do not revalidate authenticated service behavior or establish a code regression. Earlier deployment gate evidence remains in the 179/180 records.

After installing 181, confirm Apple sign-in completion/repeat/cancellation, LIMITLESS eligibility/purchase/restore, and reciprocal friend requests and room invitations on the two iPhones. Upload and automated checks do not establish these user acceptance results.

Evidence: `evidence/full-app/build181/`. Signed IPA and full local release logs are preserved under ignored `.local/release181/`; no credentials or binaries are committed. Release evidence does not change the shipped 181 source or build number.
