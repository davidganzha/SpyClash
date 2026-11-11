# SpyClash 1.0.4 (230) — integrated App Store candidate

Build 230 combines the advertising/Limitless candidate 228 with both independent
build-229 updates and the user's final FAN probability instruction.

| Included source | Change |
| --- | --- |
| `60bc0010` | Unity rewarded-generation client, server confirmation, account enrollment, Limitless access refresh and release/privacy configuration |
| `154040a8` | Three additional FAN deals, personal words, result screens and online v3 capability |
| `14b631a2`, `37f82b12` | Shared word-pack library, stable-identity client retries, updated in-app disclosure and the separate activation receipt |
| Current integration | Fresh FAN defaults: each of five surprise deals 2%, ordinary game 90%; existing explicit settings and old-only room compatibility preserved |

The two branches numbered 229 were based on build 227. Only their changes were
integrated into 228, preserving production Unity configuration and Limitless.
Both `project.yml` and the generated Xcode project use build 230; marketing
version remains 1.0.4.

## Artifact and verification

- Signed IPA: `/Users/davidganzha/Documents/SpyClash/output/AppStore-230-20261111/SpyClash-1.0.4-230.ipa`.
- SHA-256: `40bb7286f5349008dab8fb808ea8dce0ebe8571d25f7b2c948c5ca5095651d05`.
- Scheme/configuration: `SpyClash-Supabase-Public` / `SupabasePublicRelease`.
- [Artifact receipt](artifact.json) and [frozen iOS source hashes](ios-source-manifest.json).
- Final Debug integration suites: **178 passed, 0 failed, 0 skipped**.
- Native shared-generation and App Store retry suites: **15 passed, 0 failed, 0 skipped**.
- Public release configuration suite: **4 passed, 0 failed, 0 skipped**.
- Backend integration: **154 tests and 23 handler steps passed**, including 38 final FAN/core checks; relevant typechecks passed. See [backend integration](backend-integration.json).
- Signed archive and exported IPA gates passed; no source files changed between final archive start and export verification.
- Apple validation: **passed with no errors**, 11 November 2026 at 20:12 UTC. See [validation result](apple-validation.json).

The public Simulator tests use testability and no optimization only for their
test artifact. The signed IPA was archived separately with normal release
settings. An initial mixed suite was accidentally run in SupabaseDebug although
its Base44 transport/membership fixtures require Debug: 136 passed and 22 failed.
The final Debug run above passed all selected cases; native transports and public
configuration were then checked in their own schemes. No implementation was
changed to bypass those fixture failures.

The first archive was stopped when the user requested 2%/90% defaults. The IPA
linked above comes from the subsequent final archive with that change included.
The prior build-229 UI evidence remains in its original QA folder; no new device
or UI acceptance is claimed by this rebuild.

## Server and release boundary

After the user explicitly requested TestFlight upload, the exact IPA was uploaded
to app `6793534085` at 20:19 UTC on 11 November 2026. Apple accepted it with no
errors; delivery UUID `10a3e703-cc8f-44dc-8302-8f9a312d1f68`. Processing completed successfully (`VALID`). The build was assigned to the same
existing internal group as build 218, **LIMITLESS Internal QA**, at 20:23 UTC.
Its verified internal state is **IN_BETA_TESTING**. [Availability receipt](testflight-status.json),
[group-assignment receipt](testflight-group-assignment.json).
No App Review submission, public release, backend deployment, secret change or
advertising activation was performed. See [upload receipt](testflight-upload.json).

The shared-library activation receipt from the other task records `app-services`
v20. The old build-228 server packages were prepared against v19 and are now
obsolete: **do not deploy them over v20**. A future deployment must start from
fresh live source and retain the activated library. This rebuild integrates and
tests the source; it does not create a new live-source deployment package.

New online FAN deals and their defaults require an approved `full-game-core`
update. New clients advertise `fan_mode_v3`; old saved configurations without
the new deals remain compatible with v2. Local FAN behavior is in the IPA.

The advertising release still requires approved server rollout, Unity S2S
activation/secret, current privacy declarations and real callback/purchase/device
acceptance described in the [prior candidate report](../app-store-candidate-20261111/README.md).
Compilation, fixtures and Apple package validation do not establish those live
behaviors. The uploaded IPA is available for controlled acceptance in the existing internal
QA group. No external group, public beta review or public App Store release was
changed. Server changes and real purchase/reward/device acceptance remain separate.
