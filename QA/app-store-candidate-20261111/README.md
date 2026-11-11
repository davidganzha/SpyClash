# SpyClash 1.0.4 (228) — prepared advertising release candidate

**Superseded by the integrated build 230.** The server candidates below were
prepared against `app-services` v19. The separately approved shared word-pack
activation subsequently deployed v20; do not deploy the old candidate over it.
See [the build 230 report](../app-store-candidate-230-20261111/README.md).

The signed App Store IPA is built, exported and validated by Apple with no errors.
The implementation is ready for controlled integration acceptance; **public
advertising/reward delivery and a current real Apple purchase are not yet proven**.
No upload, submission, deployment, public configuration change or support message
was performed in this work.

## Artifact

- App `6793534085`, bundle `com.spyclash.ios`, version `1.0.4`, build `228`.
- Scheme `SpyClash-Supabase-Public`; configuration `SupabasePublicRelease`.
- IPA: `/Users/davidganzha/Documents/SpyClash/output/AppStore-228-20261111/SpyClash-1.0.4-228.ipa`.
- SHA-256: `e06fb48b512cbf578138aa71f221436a39c1a1d09b89a1e5d38931a9235f5239`.
- Signed archive: `/tmp/SpyClash-AppStore-228-Final/SpyClash-1.0.4-228.xcarchive`.
- [Artifact receipt and source hashes](artifact.json), [Apple validation](apple-validation.json),
  [exported IPA checks](ipa-gate.log).

The IPA contains owned Unity identifiers, real-mode configuration, all 76 reviewed
SKAdNetwork IDs, updated privacy declarations, the weekly StoreKit product and the
Live Activity extension. Preview/test ad switches and local StoreKit fixtures are
excluded from the release flow. Server configuration still controls availability.

## Implemented behavior

- Three free generations per UTC day after compatible account enrollment.
- One optional completed rewarded ad earns one additional generation only after
  the provider's signed server callback; client completion cannot mint credits.
- Account-bound attempts, duplicate callback protection, durable pending recovery,
  exactly-once reservation/refund and account-deletion cleanup.
- Verified LIMITLESS remains unlimited and has no rewarded-ad offer. Purchase,
  restore, revocation and expiry immediately invalidate obsolete allowance UI.
- Old versions retain their previous generation policy until the account first
  sends a supported status request from build 228 or later. Enrollment persists:
  later capability removal or downgrade cannot undo the quota. This is a
  compatibility policy, not binary attestation.
- Existing AdMob protocol remains compatible; Unity is selected for this release.

## Verification

| Check | Result |
| --- | --- |
| Initial iOS membership, product catalog, ad configuration and reward suites | 128 passed, 0 failed; 5 opt-in StoreKit scenarios initially skipped |
| Final reward/configuration tests after enrollment changes | 22 passed, 0 failed, 0 skipped, including 2 new capability tests |
| Final public configuration and capability checks | 4 passed, 0 failed, 0 skipped |
| Backend provider, ledger, real-handler fixtures, public gateway, native PostgreSQL | 95 passed, 0 failed |
| Base44 server-only entity security | 10 passed, 0 failed |
| Existing signed-release packaging fixtures | 81 passed, 0 failed |
| New release advertising checks | 6 passed, 0 failed |
| Signed archive and exported IPA | Passed |
| Apple archive validation of final IPA | Passed, no errors |
| Prepared website privacy patch | Applies cleanly; 3 existing content tests passed |

Public-configuration tests use testability enabled and optimization disabled only
for the test artifact; the independently archived IPA retains its normal release
settings. The initial public-test build needed this test-only override; final
public checks passed. Logs and summaries are stored beside this report.

Explicit local StoreKit execution was attempted separately: all five scenarios
stopped at the synthetic local canary with `notEntitled`, before any application
purchase. Apple's documented Simulator fix requires iOS 26.6; Apple's download
service did not offer that runtime to this Xcode installation. The canary remains
intact. This is **not** a successful purchase test or evidence of production
purchase failure. [Exact result and qualification](local-storekit-summary.json).
The weekly product is currently APPROVED in the read-only [App Store snapshot](app-store-readiness.json).

## Prepared server and website changes

Supabase candidate packages are under
`output/app-store-candidate-228/prepared-supabase`, based on freshly retrieved live
`app-services` v19 and `rewarded-generation-ssv` v2. All unrelated deployed files
remain byte-identical; the exact candidate passed the 33 native PostgreSQL checks.
Use the [manifest](supabase-unity-candidate-manifest.json) and
[reviewable diff](supabase-unity-candidate.diff); do not deploy the whole historical
checkout over production. The [Base44 package](base44-candidate-manifest.json)
contains the three affected functions and schemas; compare its source with a
fresh production read before deployment.

Create Base44 `GenerationRewardEnrollment` **before** updating `deleteAccount`,
`generationRewardAction`, and `generateWordPack`. Apply the private native
`20261111184822_rewarded_generation_enrollment.sql` migration before activation.
Public gateway JWT verification remains off for signed provider callbacks;
`app-services` retains its existing authenticated configuration.

The website policy patch is prepared in [website-privacy-draft](website-privacy-draft/PrivacyPolicy.jsx).
It updates four languages; the owning website was not changed. Its full build
still needs verification when applying the patch to the website checkout.
[Privacy/ASC declaration details](privacy-readiness.md).

## Remaining steps requiring external action or fresh approval

1. Deploy the reviewed backend/schema changes to Supabase `bbkfsgnordtdiblgdzkg`
   and Base44 app `69a0e57fa939f578082f8091`, with rollout kept disabled. Fresh
   production-source and configuration checks must precede each approved action.
2. Send [the prepared Unity request](../../release/UNITY-REWARDS-SUPPORT-REQUEST-228.md).
   Unity must enable S2S for Game ID `800429660` and issue its server-only secret;
   this cannot be manufactured by the app. Store it in the authoritative backends
   and callback gateway only after approval. [Unity's activation requirements](https://docs.unity.com/en-us/grow/ads/mediation/s2s-redeem-callbacks).
3. Publish the reviewed privacy policy, obtain Unity's actual organization seller
   entries for app-ads.txt, and update App Store privacy disclosures. Seller IDs
   are not derived from the Game ID. Missing seller entries are an advertising
   readiness concern, not established here as an Apple upload rejection.
4. Verify real Unity viewing → signed callback → exactly one earned and spent
   generation on native and legacy accounts. Verify a real Apple Sandbox purchase,
   restoration, no-ad/unlimited behavior and physical-device playback. Local
   fixture and Simulator results do not substitute for these checks.
5. Upload the exact final IPA to App Store Connect for controlled TestFlight
   acceptance only after the user confirms that operation. App Review submission,
   global rollout and public release are separately approved actions.

The prepared code and validated IPA complete local preparation. They do not make
the public advertising release complete while these external checks remain open.
