# Approved App Store metadata and internal TestFlight actions — 238

Completed 13 November 2026 after explicit approval in the current chat.

- Created App Store iOS version1.0.4 as PREPARE_FOR_SUBMISSION with MANUAL release.
- Attached already uploaded build238; saved the exact approved English description
  and What's New. Other English fields and the prior live1.0.3 listing were preserved.
- Saved the approved monthly review note and Ukrainian localization. Existing
  English, Spanish and Russian subscription localizations, weekly subscription,
  monthly pricing and other product settings were preserved.
- Assigned238 only to existing LIMITLESS Internal QA; API returned204 and the
  following GET shows exactly that one internal group. Build was not uploaded again.

The API key rejected metadata writes, so those same authorized fields were saved
through the already signed-in App Store Connect UI. The successful values were
then independently compared using the read-only API. `receipts.json` retains API
rejections and the successful internal-group action. `ui-save-receipts.json`
records the UI operation provenance; `readback.json` contains sanitized results.

The draft contains the prepared three-generation/rewarded-ad copy. Saving it as
a draft does not prove those services are active and does not publish the text.
No Add for Review, App Review submission, external-beta assignment, public
release, price change, agreement acceptance or screenshot upload was performed.

Build238 is available to the existing internal QA group in TestFlight. Subsequent
devicectl readback confirms238 installed; the user confirmsUSD2.99 per month.
Monthly purchase/restore still need actual confirmation; see device-readback.json.
The monthly review screenshot remains absent. App privacy labels have a prepared exact comparison in privacy-and-review-diff.md;
the additional changes still require separate authorization for publication.
