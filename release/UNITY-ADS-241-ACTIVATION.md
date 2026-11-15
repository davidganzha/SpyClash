# SpyClash Unity Ads production activation — 15 November 2026

The user approved deploying the three reviewed functions, installing the
Unity signing key on both servers and enabling rewarded ads for all
supported accounts. The function source was prepared at `8f22ebf1`.

## Deployment and configuration

- Supabase project `bbkfsgnordtdiblgdzkg` | `app-services` v27 → v28
  deployed with JWT verification. After both environment updates, v30 is
  active with all 84 source files byte-for-byte identical to the candidate.
  The project secret updates also advanced `full-game-core` to v19 and
  `rewarded-generation-ssv` to v6. Their code bundle hashes and JWT
  settings match the pre-activation versions.
- Base44 canonical app `69a0e57fa939f578082f8091` | `generateWordPack`
  (18 files) and `generationRewardAction` (9 files) match the candidate.
  Deployment ID `6e3d053ba3a246a19659037900cb97db`. The other 20 function
  bundles, entry points and automations match the preflight inventory.
- On both projects, configured Unity Game ID `800429660`, placement
  `BP_Rewarded_iOS`, provider `unity` and the signing key from
  [Unity request 00945449](https://support-ads.unity.com/s/cases?id=500Qv00000lpu0RIAQ).
  Supabase digest verification matched the configured values. Base44
  confirmed its secret updates and exposes name-only verification.
- On both projects, set `SPYCLASH_REWARDED_GENERATION_ENABLED=true` after
  confirming the Unity callback handlers saw the configuration. Supabase
  readback matched `true` and Base44 accepted the same update.

## Acceptance

- `app-services` without an authorization header returns HTTP 401.
- The public Supabase and Base44 Unity callbacks both return HTTP 400
  `invalid_reward_signature` for an unsigned probe.
- Supported builds enroll eligible free accounts into three daily
  generations and offer one additional generation per approved ad event.
  A genuine Unity viewing and credit spend on TestFlight 238 still need
  device verification.
- App Store 1.0.4 (238) and monthly LIMITLESS retain the remaining Apple
  review steps in the [release preflight](APP-STORE-240-PREFLIGHT.md).
  The website seller file and Unity Developer website configuration remain
  prepared for a separate publication.

The repository configuration checkpoint is 241. The iOS candidate remains
the already uploaded build 238.
