# AdMob server preparation — 1.0.4 (219)

This is a reviewable publication plan, not authorization or evidence of deployment. Read [the build 219 report](../QA/admob-readiness-219/README.md) first.

## Proposed publication, with new offers disabled

1. **Base44 app `69a0e57fa939f578082f8091` (`spyclash.com`)**: add only the `GenerationReward` entity. Publish the prepared `generationRewardAction`, `generateWordPack` and `deleteAccount` packages. Preserve every other entity and function. The package preserves live word normalization, cache version, CASADA behavior outside the reward rollout, and live deletion helpers.
2. **Supabase project `bbkfsgnordtdiblgdzkg`**: apply only migration `20261105224817_rewarded_generation_credits` before publishing any handler that reads `charge_source`. Publish the minimal `app-services` package based on observed live v17, with `verify_jwt=true`. Publish the dedicated `rewarded-generation-ssv` package with `verify_jwt=false`; its authorization is Google's ECDSA signature plus the issued account/attempt/token/unit/reward checks. Preserve other functions, auth settings, push and game-core files.
3. On **both backends**, explicitly set `SPYCLASH_REWARDED_GENERATION_ENABLED=false` and `ADMOB_REWARDED_AD_UNIT_ID=ca-app-pub-5081830513960558/6816674766`. Do not set the feature flag to true during publication checks.
4. After readback succeeds, configure **AdMob publisher `pub-5081830513960558`, rewarded unit `6816674766`** with callback `https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv`. Keep the reward at `1 generation`.

Use the frozen candidate packages and their SHA256 manifests, not a wholesale deployment from the current repository. The repository also contains unrelated server work that is not part of this publication.

Before executing, compare current live function versions and relevant schema/configuration presence with the recorded baseline. Stop and rebase the candidate if another change has occurred. Check candidate hashes again immediately before upload.

## Readback after the approved publication

- Confirm the additive schema/migration and exact published function versions/hashes.
- Confirm `app-services` still requires JWT; only the new callback is public.
- An unsigned GET to the new callback must fail without creating a reward; do not send a synthetic signed grant to a real account.
- Confirm the callback URL and `1 generation` reward in AdMob.
- Confirm new offers remain disabled. Existing generation access must remain intact.

This step does not publish an iOS build, enable advertisements, activate the three-per-day limit, approve the AdMob account, or prove real Google reward delivery.

## Separate activation prerequisites

The global feature switch affects existing clients, including build 218 which cannot show live ads. A real end-to-end test needs a reviewed isolated test backend or test-account rollout before changing that global switch. The present callback forwards legacy claims only to canonical production Base44; a native-only test does not validate that legacy path.

Verify actual Google callback delivery, exactly one extra generation, retry/relaunch recovery, both account types and LIMITLESS. Finish applicable consent/privacy configuration, privacy-options lifecycle, live website policy, App Store declarations and attribution setup before preparing an ad-enabled public release. Obtain separate fresh approval for that later activation and distribution.

## Rollback

Keep new offers disabled first. Preserve issued reward data and the signed callback path so an already earned reward is not lost. Restore prior function bundles only after checking compatibility with any issued attempts. The schema addition is not a reason to delete data or drop tables.
