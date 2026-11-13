# SpyClash 1.0.4 (238) — prepared release sequence

This is a reviewable plan, not authorization. Every production operation needs
fresh explicit confirmation in the current chat. Build, signing, validation,
Git checkpoints and local tests do not constitute upload, activation or release.

Execution update, 13 November 2026: build238 was uploaded and processed VALID;
the separately approved three Supabase/four Base44 functions and two additive
schemas are deployed. The draft1.0.4 and internal LIMITLESS QA assignment are
prepared in App Store Connect. See `APP-STORE-238-UPLOAD.md`,
`../QA/app-store-server-rollout-238/README.md` and `../QA/app-store-metadata-238/`.
The actual published website required the corrected policy-only candidate in
`website-privacy-239/README.md`, now published after approval. The earlier
four-language website candidate below was not deployed. iOS binary238 is unchanged;
239 is the scoped website-content source checkpoint. Activation and review gates
below remain separate until their own receipts exist.

## Exact targets

- App Store Connect app `6793534085`, bundle `com.spyclash.ios`.
- New version `1.0.4`, build `238`, manual public release.
- Monthly subscription `6825982027`, product
  `com.spyclash.ios.limitless.monthly`, one month, USA USD 2.99.
- Supabase project `bbkfsgnordtdiblgdzkg`: reviewed `app-services`,
  `full-game-core` and `rewarded-generation-ssv` bundles only.
- Base44 canonical app `69a0e57fa939f578082f8091`: reviewed
  `app-store-entitlement`, `generateWordPack`, `generationRewardAction`,
  `deleteAccount` and GenerationRewardEnrollment schema only.
- Public privacy page: `https://spyclash.com/privacypolicy`, corrected actual-live
  candidate in `website-privacy-239/`. No other website feature change is included.

## Server preparation and rollout

1. Re-read live versions and compare the manifest baseline before deployment.
   Preserve unrelated live code; do not deploy whole stale branches or use
   Base44 `eject`. Use the exact reviewed bundles and reconstructed hashes.
2. Apply the additive reward enrollment migration and Base44 schema listed in
   [REWARDS-AND-SERVICES-238.md](REWARDS-AND-SERVICES-238.md).
3. Deploy the three Supabase and four Base44 function bundles, retaining all
   current production credentials, ownership checks and unrelated configuration.
   Keep advertising activation off until the requirements below are met.
4. Complete monthly product review metadata using
   [APP-STORE-238-METADATA.md](APP-STORE-238-METADATA.md). Add the current monthly
   paywall review screenshot and review note. Its observed state is still
   MISSING_METADATA; approved weekly subscriptions remain untouched.
5. Separately authorize the monthly checkout flag
   `SPYCLASH_LIMITLESS_APPLE_MONTHLY_PURCHASE_ENABLED=true` on both backends once
   their deployed support and Apple sandbox product availability are verified.
   Keep `APPLE_IAP_PRODUCT_ID` weekly for older-client compatibility. Do not
   transfer existing entitlements or remove weekly restore support.
6. Publish the reviewed privacy update and reconcile App Store privacy details
   with the shipped SDK manifests before advertising submission.

## Unity activation gate

The release binary contains the production Unity Game ID `800429660` and
placement `BP_Rewarded_iOS`; test mode is off. This does not establish live ad
delivery. Current production reward activation is off; the three-generation
policy is not yet active for those users.

Unity must enable signed server-to-server callbacks and supply the signing
secret securely. The exact prepared request is
[UNITY-REWARDS-SUPPORT-REQUEST-228.md](UNITY-REWARDS-SUPPORT-REQUEST-228.md).
Sending it requires explicit authorization; it has not been sent. Obtain the
organization-specific app-ads.txt seller entries; do not derive them from the
game ID. Store secrets only in approved server secret storage.

After configuration, prove one genuine completed ad yields exactly one reward,
duplicate callbacks yield none, and both native Game Center and legacy login
paths can spend the credit. Then enable the reviewed provider/global flags and
confirm enrolled accounts see three free generations. If confirmation is absent,
do not turn on a path that can show ads without granting the earned reward.

## App Store delivery and acceptance

After approval, upload the exact validated IPA identified in
`QA/app-store-complete-238/artifact.json`; wait for VALID processing and verify
the build number and App Store eligibility. Complete the 1.0.4 record and attach
238. Do not silently rebuild a different IPA under the same evidence.

Before App Review submission, verify on the distribution candidate:

- Launch and relaunch; actual Apple, Google and Game Center sign-in as applicable.
- Monthly price/period, purchase, server-granted access, restore and restart.
- Existing weekly entitlement restoration without another purchase.
- Three free generations, verified additional ad generation and LIMITLESS bypass.
- Multiplayer start/intro, FAN vote, return to lobby, and invitation behavior.
- Account deletion continues to erase reward enrollment and existing private data.

The user accepted LIMITLESS on build232 through Apple earlier in this chat;
that is not acceptance of monthly purchase or this integrated build238.
Local StoreKit tests are currently blocked by the simulator's `notEntitled`
canary and do not replace device checks.

Only after the required acceptance and fresh approval should the app version and
monthly subscription be submitted for review. Public release remains a separate
manual action after Apple's approval.
