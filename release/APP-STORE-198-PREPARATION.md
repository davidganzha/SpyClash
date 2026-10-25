# SpyClash 1.0.3 (198): public configuration preparation

Build 198 carries the automatic saved-action recovery from build 197 into an explicit App Store configuration. The game no longer asks players to press a saved-action retry button. This checkpoint prepares the client; it does not establish production backend readiness or record an upload/submission.

## Build identity

- App Store Connect app: `6793534085`; bundle: `com.spyclash.ios`.
- Scheme/configuration: `SpyClash-Supabase-Public` / `SupabasePublicRelease`.
- Version/build: `1.0.3` / `198`, including the widget.
- Backend: existing `bbkfsgnordtdiblgdzkg` project and the original `spyclash` callback scheme.
- Public configuration enables the existing Apple/Google/billing integrations and full account deletion. Legacy remote push remains disabled.
- Export with `testFlightInternalTestingOnly=false` and `manageAppVersionAndBuildNumber=false`. Build 197 was uploaded as `INTERNAL_ONLY` and cannot be selected for public App Review.

The candidate configuration remains unchanged and the public release gate continues to reject candidate builds. The new gate requires the explicit public resource, verifies its capabilities and absence of candidate/staging resources, and preserves signing/entitlement checks. Package validation does not prove that the corresponding backend features are deployed.

## Verification

- Public configuration runtime tests: 3 passed, 0 failed, 0 skipped on iOS 26.5 Simulator.
- Release bundle gate fixtures: 68 passed, 0 failed.
- Device archive succeeded; the signed public bundle gate passed for the main app and embedded widget, including production APNs and Sign in with Apple entitlements.
- Dedicated public test target avoids importing unrelated DEBUG-only tests into the release configuration; CI requires all three tests to execute.
- Independent review confirmed the recovery, authentication and candidate runtime files are unchanged from `e5e33b1c`, apart from the explicit public configuration selection in `SupabaseAppRuntime`.
- The build-197 multiplayer regression run passed: [GitHub Actions 39765601293](https://github.com/davidganzha/SpyClash/actions/runs/39765601293). The new configuration has its own CI job.

## Required before public submission

Live inspection on 2026-10-25 found that the full-account-deletion server protocol is not yet active. The public flag alone cannot implement deletion. The matching Base44/Supabase implementation, recovery worker and migration-archive erasure must be reviewed, explicitly authorized for production, deployed and verified with disposable accounts before submitting this configuration for public review. Historical Apple credential ownership must be established without inferring account ownership from matching email addresses.

The existing public App Store version is 1.0.2. Preparation reuses its store metadata and review-contact fields and drafts new 1.0.3 release notes. No demo credentials or signing secrets belong in this repository. Neither a signed archive nor passing source tests proves production deletion, two-phone gameplay acceptance, Apple processing or App Review approval.
