# Build 238 server preparation

The local combined candidate is complete and verified for the active client
features. It is **not deployed or activated**. Source changes alone do not
change the current production allowance or enable Unity callbacks.

Detailed source hashes, patches, test evidence and repeatable local preparation
are in `QA/app-store-complete-238/rewards/README.md`. The accidental Base44 copy
incident and its separately approved cleanup are recorded in
`QA/app-store-complete-238/incident.md`; the copy export is excluded from every
release candidate.

The reward policy is three free generations per UTC day for enrolled supported
accounts, then one additional generation per server-verified ad. Old unenrolled
accounts keep ten daily generations. LIMITLESS stays unlimited. Enrollment is
durable, so omitting or downgrading client capabilities cannot restore the old
allowance. A client ad-completion callback never grants credit by itself.

Before activation, the Base44 GenerationRewardEnrollment schema and native
private enrollment migration must be installed, the exact reviewed function
bundles deployed, and Unity must enable S2S callbacks and provide its secret.
The secret belongs only on the servers. The current preparation has no
Unity-issued S2S secret and no verified real Unity callback. Support setup and
real native/legacy reward acceptance remain external release prerequisites.

Unity game ID is `800429660`; placement is `BP_Rewarded_iOS`. The prepared
callback URL is:

```text
https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv?provider=unity&game_id=800429660&placement_id=BP_Rewarded_iOS
```

The reviewed configuration requirements for both the Supabase and Base44
reward handlers are:

| Setting | Required value for later activation |
| --- | --- |
| `SPYCLASH_REWARDED_AD_PROVIDER` | `unity` |
| `UNITY_ADS_GAME_ID` | `800429660` |
| `UNITY_ADS_REWARDED_PLACEMENT_ID` | `BP_Rewarded_iOS` |
| `UNITY_ADS_S2S_SECRET` | Actual Unity-issued secret, installed only on servers |
| `SPYCLASH_REWARDED_GENERATION_ENABLED` | Exact `true`, only after prerequisites and separate rollout approval |

No configuration is changed by this document. Keep existing billing and AI
configuration intact. The dedicated SSV function retains its existing public
callback setting (`verify_jwt=false`); app-services retains `verify_jwt=true`.

Unity's [official S2S documentation](https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks)
requires Support activation and supplies the shared signing secret. Confirm
the fixed query parameters are covered by the provider signature. The existing
`release/UNITY-REWARDS-SUPPORT-REQUEST-228.md` contains the prepared request; no
message was sent during this work. Connected Gmail searches found no matching
reply; that is not proof that no support ticket exists elsewhere.

Monthly purchases additionally need approved Apple metadata and the separate
monthly checkout flag. See `QA/app-store-complete-238/monthly/README.md`.
None of the server, schema, Unity, monthly, or rollout prerequisites is
authorization to mutate production. Each production operation remains subject
to the current chat's explicit approval requirement.
