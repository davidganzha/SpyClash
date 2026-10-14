# SpyClash 1.0.3 (176) — approved internal delivery

Source commit: `b1bfceb1339c79a85621cc2fd950898daf70bf81`. The user explicitly authorized the canonical Base44 Apple fix, the subscription bridge in the existing isolated Supabase project, and main SpyClash 1.0.3 (176) in TestFlight Internal Only for David Ganzha. App Store submission was excluded.

## Server deployment

- Canonical Base44 app `69a0e57fa939f578082f8091`: only `appleAuthBroker` deployed at 2026-10-14 10:32:32 UTC. A fresh readback matched all 14 approved runtime/configuration hashes. Three safe server-side HTTP probes passed. Local shell probes were blocked by Cloudflare (403), so they are not counted as successful broker checks. No website or provider-configuration change was made.
- Isolated Supabase project `bbkfsgnordtdiblgdzkg`: only `app-services` code changed, with all 55 approved file hashes preserved. Initial deployment v5 became metadata v7 after configuration updates; code SHA-256 is `7fcfa6ed615ff40755d3178d809a1f65b9b4efab74e145894ca1eafda8c383df`. Function is ACTIVE with JWT verification enabled; project is ACTIVE_HEALTHY. No schema migration occurred.
- Four project flags are confirmed: `APP_BILLING_PROVIDER=base44`, `APP_LEGACY_BILLING_ENABLED=true`, `APP_LEGACY_PURCHASES_ENABLED=true`, `SPYCLASH_LIMITLESS_ENABLED=true`. The last flag enables existing verified-entitlement enforcement. Production Base44 configuration and subscription products/prices were not changed.
- Existing synthetic Supabase account authentication and profile ownership passed. Missing/invalid JWTs and a billing request without the separate Base44 credential were rejected. No real purchase, purchase preparation, or membership reconciliation was performed by these probes.

Google callback source and the deployed broker's Google helper/provider modules match their predeployment baseline. Physical Google regression acceptance for 176 remains separate from these hash checks and the earlier successful 173 login.

## Signed artifact and Apple delivery

- Fresh source snapshot from the exact source commit; 1,154 of 1,156 tracked files byte-identical. The only temporary differences are manual distribution-signing settings in `project.yml` and the generated Xcode project.
- Signed main app `com.spyclash.ios` and widget `com.spyclash.ios.widgets`, both 1.0.3 (176), team `3Z64QKNL54`, using existing SpyClash App Store profiles. Apple Sign In entitlement is present; `get-task-allow=false`.
- Exported `TFInternalTestingOnly=true`. Runtime configuration points exclusively to the isolated Supabase project, enables Apple/Google and legacy billing, and keeps push/account deletion disabled.
- Independent IPA audit: **19/19 PASS**. Signed IPA SHA-256: `f495cbeea4547780646569d96113554b77ca69744eb997ea2b670b47b31448a3`; size 12,540,523 bytes.
- Apple validation and upload both succeeded without errors. Upload completed 2026-10-14 10:36:24 UTC; delivery UUID `1a5ae807-b59f-406a-bc55-1bf55a58d3dd`.
- Apple processing is **VALID**, audience **INTERNAL_ONLY**, internal state **IN_BETA_TESTING**, external state **NOT_APPLICABLE**. Assignment completed and read back at 2026-10-14 12:36:51 UTC.
- The build is assigned only to existing group `Supabase Main Internal QA` (`f41d2529-7451-4605-857b-d257d34df23b`), which has exactly one tester: David Ganzha (`569dc033-570c-42f7-bbc3-611f6c9cb527`). No individual testers, other group assignments, automatic access or public link were enabled for this build.
- Final independent App Store Connect readback at 2026-10-14 12:37:57 UTC passed **17/17 checks**. App Store versions 1.0.2, 1.0.1 and 1.0 retain their original IDs and READY_FOR_SALE state. No App Store version 1.0.3 was created and no App Store submission/release was performed.

The general production release gate still rejects this hybrid main candidate. The explicit internal-only authorization does not remove that gate or establish App Store readiness.

## Evidence and remaining acceptance

Sanitized records are in `evidence/full-app/build176/`: `apple-native-v2-deployment.json`, `billing-deployment-receipt.json`, `billing-config-proof.json`, `billing-canonical-config-readonly.json`, `ipa-independent-audit.json`, `apple-validation.json`, `apple-upload.json`, `asc-distribution-preflight.json`, `testflight-main-delivery.json`, and `asc-final-independent-readback.json`.

Canonical Base44 read-only configuration metadata confirms both existing billing rollout keys and all six Apple IAP configuration keys are present. It does not expose effective boolean values, so enabled/disabled status of those upstream gates is not independently proved. No provider membership reconciliation or purchase-preparation call was used to claim readiness.

The earlier source validation remains recorded in [APPLE-BILLING-176.md](APPLE-BILLING-176.md): 135 native tests, 49 hybrid Staging tests, 66 Google callback tests, 13 broker tests, and 13 billing domain/HTTP tests passed. No application source was changed during this delivery.

Still requires Ganzha with installed 176: Apple sign-in/repeat/cancel, Google returning to the original profile, and user-controlled sandbox weekly purchase/restore with reconnection and account-switch cases. Apple private-relay accounts must not be merged with Google accounts based on email resemblance. Upload, signature checks and server probes do not prove these user flows.
