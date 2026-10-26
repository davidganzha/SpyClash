# SpyClash 1.0.3 (199): public release preparation

Build 199 supersedes the locally prepared, unuploaded build 198. It keeps build 197's automatic saved-game-action recovery and the explicit public configuration introduced in [build 198](APP-STORE-198-PREPARATION.md).

## Additional client fix

Full account deletion now retains its exact saved request after connection loss, HTTP 408/425/429, retryable errors and an unresolved server intent. A successful response must confirm both `success=true` and `original_account_deleted=true` before the saved request is acknowledged. A late response from a logged-out account cannot acknowledge its intent. Definitive ownership/validation rejections still release the request.

This change is restricted to writes with `service=profile`, `action=delete`, `deletion_scope=account`. Gameplay recovery, provider authentication and other mutation handling are unchanged.

## Local verification

Four focused native tests passed with zero failures/skips. They cover ten unresolved response cases across fresh session instances, credential revalidation failure, three definitive rejections, and a late error after logout. The tests verify exact request body/UUID reuse and journal acknowledgement only after full deletion is confirmed. The existing multiplayer CI script includes this test class.

The public configuration's three runtime tests and 68 packaging fixtures passed for build 198, including its signed archive and exported IPA. Apple archive validation passed for that superseded IPA. These checks must be repeated against the final build-199 artifact; build-198 artifact validation is not build-199 delivery evidence.

## Delivery target and remaining prerequisite

Use `SpyClash-Supabase-Public` / `SupabasePublicRelease`, app `6793534085`, bundle `com.spyclash.ios`, version `1.0.3`, build `199`. Export for public App Store eligibility with internal-only testing disabled and automatic build-number adjustment disabled.

The production full-account-deletion package must be explicitly authorized, deployed and verified before public submission. Its archive erasure must preserve other accounts, handle historical aliases and survive a lost client journal. The historical Apple selector key must be verified before enabling deletion. A public client flag, a signed archive and local tests do not establish this server readiness.

No build-198 or build-199 upload, App Review submission or public release is recorded by this preparation document. Store metadata drafts retain the existing public description/review-contact setup and update the version's release notes. Secrets and review credentials are not stored here.
