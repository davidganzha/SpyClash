# SpyClash App Review preparation — 20 November 2026

Execution update: the approved metadata changes and the subsequently approved
actual paywall screenshot were saved. Apple also required two new age answers,
which received separate approval. See [checkpoint 254](APP-REVIEW-254-METADATA.md).
The following records the preparation before those writes.

Status: two metadata corrections prepared, not applied. No upload, App Store
write, review submission, public release or production deletion was performed.

## Current live state

Fresh App Store Connect GETs confirmed app `6793534085`, iOS `1.0.4`, version
`a29db5e9-0922-42cf-b084-e5bf5c51b348`, `PREPARE_FOR_SUBMISSION`, manual release,
with build 238 still attached. Latest uploaded build 242 is internal-only. The
current Apple sign-in source has not been uploaded as a distribution candidate.

All three CI jobs for source checkpoint 252 (`e9bc467c`) passed:
https://github.com/davidganzha/SpyClash/actions/runs/44730978903.
Checkpoint 253 records this preparation; app implementation is unchanged.

Monthly product `6825982027` remains `MISSING_METADATA`. Its review note and
en-US/es-ES/ru/uk localizations are present. Its actual `appStoreReviewScreenshot`
relationship is empty. The subscription-version promotion-image endpoint is
not evidence of a missing review screenshot.

## Exact proposed corrections

1. PATCH only `advertising=true` on the editable age-rating declaration
   `08a99022-5f91-48eb-bde3-bd658f2c860e`. All other answers remain unchanged.
   [Payload](../QA/app-review-253/age-rating-advertising.json).
2. PATCH only `notes` on app-review detail `808627a0-5949-4c3f-9038-c45ed18fe1ee`.
   Replace the stale 1.0.3 (200) authentication introduction with current 1.0.4
   native Apple/Google/email/Game Center instructions; replace the weekly new
   checkout paragraph with monthly checkout and preserved weekly restoration.
   [Exact before/after fragments](../QA/app-review-253/review-notes-replacements.json).
   Other notes, contact details and demo-account credentials are retained.

The full private payload is ignored under `.local/release-next-20261120/`.
Before any write, re-read the exact draft, declaration and review notes; require
each old fragment once. Stop on drift. Apply only after fresh confirmation of
these two operations under `AGENTS.md`. Read back the values and unchanged fields.
Neither operation submits the app or publishes App Privacy labels.

Apple includes video/playable ads in its advertising definition:
https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/.

## Remaining release acceptance

- A real first Apple login with an unused Apple ID and session restoration on
  iPhone. Local real Auth/DB registration checks passed; the physical step is
  not complete.
- Deleting a disposable Apple account with actual Apple token revocation and
  confirmed data removal. Do not delete an existing real user for this check.
  Apple guidance: https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion.
- Monthly purchase, entitlement, restore and existing weekly restoration on the
  final distribution candidate; genuine rewarded viewing, one credit and spend.
- An unaltered monthly paywall review screenshot with a genuinely loaded price.
  No purchase is required for capture. A preview's fixed price is insufficient.
- Review and reconcile the current App Privacy declaration with the final SDK
  configuration; the proposed age-rating correction does not publish labels.
- Prepare and validate a distribution-signed current candidate, then separately
  authorize upload and attachment to 1.0.4. App Review and release follow their
  own approval and acceptance steps.

The login keychain currently exposes only the approved Apple Development
identity. No distribution signing route was established by this audit. No old
keychain, Potuzhno signer, certificate creation or revocation was attempted.
The paired iPhones are disconnected. iPhone Mirroring reports an iCloud-sync
problem, so a new physical paywall capture was not obtained.

Sanitized current facts: [preflight summary](../QA/app-review-253/preflight-summary.json).
Private raw API snapshots and local audit scripts stay outside the checkpoint.
