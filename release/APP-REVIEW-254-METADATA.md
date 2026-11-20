# SpyClash App Store metadata completion — 20 November 2026

After explicit approvals in this chat, the following changes were saved to
App Store Connect app `6793534085`. Source checkpoint 254 records the outcome;
app implementation and marketing version 1.0.4 are unchanged.

## Verified changes

- App-review detail `808627a0-5949-4c3f-9038-c45ed18fe1ee` now contains the two
  approved paragraph replacements from checkpoint 253: current native Apple,
  Google, email/password and Game Center instructions; monthly LIMITLESS
  checkout with existing weekly restoration. The rest of the review detail
  was preserved and read back after the other operations.
- Monthly subscription `6825982027` has review screenshot
  `76d1610b-7509-441b-800c-631781bb9a1f`, `COMPLETE`. This is the exact unaltered
  PNG captured from Ganzha running development build 247: 1125 x 2436,
  605,584 bytes; SHA-256
  `5ddcdf5a4bbf71d67290ce510b2f17e384350d1a7e887e2287f735b9f904ed5d`;
  MD5 `1e94eca9ada07cbb8fa22aed9c68fe11`. Apple's source checksum and dimensions
  match. The screen shows the genuine loaded StoreKit monthly price,
  `2,99 $ / месяц` as displayed, and the subscription button. No purchase or
  restoration was performed. Apple names the stored asset `SOURCE`.
- Editable age declaration `08a99022-5f91-48eb-bde3-bd658f2c860e` now records
  advertising=true, sharedLocation=true and datingAndRelationships=false.
  Apple required the two newly introduced answers before any older answer
  could be updated. The user separately approved those two additions. Radar
  exposes nearby-player proximity/direction; the app has no dating feature.
  The displayed general rating remains 13+.

Apple's wizard normalized the inherited contests enum from
`FREQUENT_OR_INTENSE` to `FREQUENT`. The same frequent-contests radio choice was
already selected before saving and was not changed. The API comparison found
this representation change plus the three approved answers, with every other
age attribute unchanged. Do not describe the readback as only three raw JSON
attributes changing.

The API key permits reads but returned 403 for the attempted age update and
screenshot reservation; the response explicitly said the key does not allow
the request. Authorized writes were completed using the user's normal App Store
Connect session. The image was selected through macOS's ordinary file picker
from a byte-identical temporary copy. No browser file-access permission change
was needed.

Sanitized API evidence: [metadata readback](../QA/app-review-254/metadata-readback.json).
Exact approved age values: [declaration payload](../QA/app-review-254/age-rating-completion.json).
Raw responses, screenshots and the original PNG remain private under
`.local/release-next-20261120/`.

## Remaining release work

App version 1.0.4 is still `PREPARE_FOR_SUBMISSION`, manual release, linked to
build 238. Latest uploaded build is 242 and internal-only. Current Apple sign-in
source needs its own distribution-signed candidate, validation and separately
approved upload/attachment. The installed development build remains 247.

Physical acceptance remains for first login with a genuinely new Apple ID,
Apple account deletion and real token revocation on a disposable account,
monthly purchase/entitlement/restore, prior weekly restore, and a current
rewarded-ad credit/spend on the final candidate. The current App Privacy
declaration also needs reconciliation with the final SDK configuration.

The version page displayed separate Mainland China safety/AIGC declaration
notices with a 31 January 2027 deadline for existing apps. Their applicability
to the intended territories remains a separate review; no market availability
or compliance declaration was changed here.

No App Review submission, subscription submission or public release was made.
