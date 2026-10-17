# SpyClash 1.0.3 (182) — internal delivery

17 October 2026. Source: `46785c8e83dceaf4ba0bbb4520a97bd7309752cf`, branch `davidganzha/supabase-game-core`. The user explicitly approved signing and uploading 182 as TestFlight Internal Only for David and Dima after reviewing the Apple sign-in fix.

## Delivered change

Apple authorization retains its native sheet. The subsequent session completion runs in an isolated, unpresented WebKit view while the native animation stays visible. The visible browser presentation and artificial four-second animation minimum are removed. Existing account binding and Google behavior are preserved. Implementation and the 67/67 test results are documented in `APPLE-SIGN-IN-182.md`.

## Signed artifact and Apple processing

A fresh snapshot of the exact committed source was archived using `SpyClash-Supabase-Main-Candidate` / `SupabaseRelease` and the same existing distribution identity and profiles as 181. Only signing settings in the disposable snapshot differed. The repository and signing credentials/settings were unchanged. Main app and widget are both 1.0.3 (182).

Archive verification passed 17/17 checks; an independent exported-IPA audit passed 19/19, including strict signatures, exact bundle/team/profile identities, the Apple entitlement, internal-only marker, committed runtime configuration, account/auth source provenance and secret/test-fixture exclusion. Export set `testFlightInternalTestingOnly=true` and `manageAppVersionAndBuildNumber=false`.

IPA SHA-256: `a533fa0163752812fe82e352a1501aa63253782b3d575481a61e81bba6495a33` (12,711,835 bytes). Apple validation and upload both succeeded. Delivery/build ID: `1fd9df6e-d74c-4668-84fd-823faa59f40e`.

Independent App Store Connect readback at 20:50:41 UTC confirmed `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING`, and external state `NOT_APPLICABLE`.

## Audience and scope

The sole assignment was build 182 to the existing private `LIMITLESS Internal QA` group, whose only members are David Ganzha and Dima Ianushevych. All 15 final portal checks passed: no individual tester assignments or automatic all-build access, unchanged group controls/membership, unchanged earlier build assignments, and unchanged App Store versions and attached builds. No external testing, App Review submission or App Store release was performed.

There were no backend or website changes during this release. Existing Apple/LIMITLESS and friends/invitations server changes remain as deployed for 181.

Install 182 from TestFlight to verify native Apple authorization, Face ID, animation, arrival in the existing account, repeat sign-in and cancellation on the iPhone. Portal readiness and automated tests do not establish physical-device acceptance.

Release receipts are in `evidence/full-app/build182/`. The signed IPA, archive, source manifest and full local logs are preserved under ignored `.local/release182/`. This delivery evidence does not change the shipped source or increment its build number.
