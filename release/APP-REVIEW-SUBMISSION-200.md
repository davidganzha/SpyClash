# App Review submission — SpyClash 1.0.3 (200)

The user explicitly confirmed submission of this exact version and build with
manual publication after Apple approval. On 27 October 2026 at 16:57
Europe/Bratislava, App Store Connect accepted the submission and displayed
`Ожидание проверки` (Waiting for Review).

- App: `6793534085`, bundle `com.spyclash.ios`.
- Version: `1.0.3`, ID `6c6d03d7-8b84-4ed1-b315-7cf6acb9c5b2`.
- Build: `200`, ID `049e9931-16d7-4203-a65f-aa9d2972830e`.
- Submission: `994a47a0-317a-4d1e-bde8-ec853b64633c`.
- Exactly one submitted item: the iOS app version `1.0.3 (200)`.
- Release selection at submission: `MANUAL`.

[Apple submission details](https://appstoreconnect.apple.com/apps/6793534085/distribution/reviewsubmissions/details/994a47a0-317a-4d1e-bde8-ec853b64633c)

The UI first confirmed one item submitted, then showed the submission and its
app-version item both waiting for review. The details page was retained for the
user. This is a review submission, not an Apple approval or public release.

An independent read-only Apple API check at `2026-10-27T15:58:35.161Z`
confirmed version state `WAITING_FOR_REVIEW`, the exact attached build 200
(`VALID`, `APP_STORE_ELIGIBLE`), and `releaseType=MANUAL`. The matching review
submission is also `WAITING_FOR_REVIEW`, with submitted time
`2026-10-27T15:57:52.649Z`. The API key could not read individual submission
items; their count and exact version/build were verified in the UI instead.
Sanitized local readback: `.local/appstore200-submission/after-submission.json`.

## Artifact and verification boundaries

The uploaded client remains frozen at source `da2e8584` and IPA SHA256
`f2ad7bd7a2e7101258bd8546f3def7c9a93f329e70db97a6c1cd612208abe99c`.
No rebuild, reupload, new client version, or production-server change was made
as part of this submission. This document is an administrative release record;
the backend checkpoint remains 204 and the submitted client remains 200.

[Checkpoint 204](PUBLIC-DELETION-ACTIVATION-204.md) records the server readiness,
four untouched Apple records, and actual Simulator classic-login/onboarding/
session-restoration checks. Physical-device Game Center authentication, StoreKit
purchase/restore, paid AI generation and real account deletion remain separate
unexercised acceptance checks. Apple review completion is pending.
