# SpyClash 1.0 (40) — release and cutover evidence

Prepared on 28 July 2026 and updated after the approved Production cutover on
29 July 2026 for Apple ID `6793534085`, team
`David Ganzha (3Z64QKNL54)`, bundle ID `com.spyclash.ios`, Base44 app
`69a0e57fa939f578082f8091`, and `https://spyclash.com`.

Build 40 is not uploaded or selected in App Store Connect. It is not submitted
to App Review, promoted through TestFlight, or released. The approved Base44
push-only recovery and exact six-file Web deployment described below are the
only Production mutations recorded by this checkpoint.

## iOS candidate

- Marketing version: `1.0`
- Current project version: `40`
- `project.yml` and `SpyClash.xcodeproj/project.pbxproj`: synchronized
- Release Simulator build/install/launch: passed on iPhone 17 Pro Max,
  iOS 26.5
- Runtime UI snapshot: `SpyClash version 1.40v`
- Debug test configuration: `42/42` passed
- Release bundle gate: passed for `com.spyclash.ios 1.0 (40)`
- Release gate regression suite: `18/18` passed
- Embedded Live Activity extension: present
- 1024 px opaque App Store icon: present
- Privacy manifest: exact match to reviewed source
- Audio/playback paths and `.storekit`: absent

The Simulator bundle is locally signed only. Effective distribution entitlement
checks are therefore not a substitute for the final Apple Distribution archive,
provisioning, or physical-device proof.

## Notification Production state

The approved Step B attempt for plan
`4896ee8d3d852edd634f336da7ca919f6e3d627691bcf16aef5d6ce3359ac5c5`
partially applied at `2026-07-28T11:37:08Z`. Base44 accepted the reviewed
`notificationAction`, `communityAction`, `gameRoomAction`, and `deleteAccount`,
then rejected `pushNotificationAction` because minute schedules require an
interval of at least five minutes.

Fresh read-only inspection proved:

- Production functions: `17`
- Production entities: `22`
- Schema digest:
  `1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e`
- The four accepted functions match the reviewed Step B target
- `pushNotificationAction` remains exactly at its pre-Step-B version
- The other twelve functions remain at their reviewed baseline
- The old five-function Step B plan must not be rerun

The dedicated read-only recovery plan is:

- Plan digest:
  `b38454950788b0a15ca5f7ece7dc2b7df471eeba50d5020b0e7e0de57c896a4d`
- Change only: `pushNotificationAction`
- Preserve byte-for-byte: the other `16` functions
- Delete/add functions: none
- Schema/data/secrets/site changes: none
- Retry drain: every `5` minutes, bounded batch `64`

Local recovery validation passed: deterministic Production preflight, shell
syntax, isolated confirmation/JIT/scoped-deploy/postflight contract, and the
complete Base44 suite (`470 passed`, `0 failed`).

The approved push-only recovery was deployed on 29 July 2026. Exact postflight
at `2026-07-29T06:59:00Z` proved:

- Deployment status: `0`
- Function postflight status: `0`
- Schema postflight status: `0`
- Reviewed-stage match: `true`
- `pushNotificationAction` expected/actual digest:
  `c49ec77a91f2e4c3d4b9bb1e04c5a9fadd55250c53b8abad42aad7b27b7902d0`
- Other 16 functions expected/actual inventory digest:
  `73d958003307704b18ecd9d09672ad676d36c5ba811d6d661f481930e1e1948e`
- Other 16 functions expected/actual byte digest:
  `4430dde8f17ebc1e18c728ddc9e0d3dbf53209e86b6addad9cf9010469a849f0`
- Schema expected/actual digest:
  `1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e`

Production still contains exactly `17` functions. No function was added or
deleted, the other 16 functions remained byte-for-byte unchanged, and schema,
entities, data, secrets, auth configuration, and the site were not changed by
the recovery operation.

Partial-attempt postflight evidence is stored locally at
`.base44-cutover/evidence/notification-step-b-functions/20260728T113708Z-60712/postflight.json`.
The final recovery postflight is stored at
`.base44-cutover/evidence/notification-step-b-push-recovery/latest-postflight.json`.

## Interactive Web candidate

- Candidate commit: `fb0860f0a603f5020ca059f48ae930d213ae0ce9`
- Dist files: `6`
- `DIST_INVENTORY_SHA256`:
  `c02535dfd3e7d1c54f8bbdecb5e210cb2c209dc822b10e66975709e7d0b3bb19`
- Public support email: `yanushevych.mr@gmail.com`
- Deployment state: deployed to Base44 Production and `https://spyclash.com`

The live CSS, JavaScript, icons, and manifest match the reviewed candidate
byte-for-byte:

- `assets/index-0l8dwMq3.css`:
  `213b1b836274d0aeffbead7931d41cc43f8482cc7eaec8b955dfd20c2dd077b3`
- `assets/index-weIm6iRv.js`:
  `b8f816ed0d7c7364ddfb08fb500dcdee15e98aed9e45a0dd4acafd40bfbd90d7`
- `icon-192.png`:
  `f87e24ccca18273ac41aa11d5b7971ff87509231f606a872d2cae1554a39c7b5`
- `icon-512.png`:
  `bf034fa28c99e7242c1b58abfbf202515cd9386e07424ef558f59285cadcd15e`
- `manifest.json`:
  `25511fc511061469990b367cc1c52f14622c7a70b50d8f3bbf2d844d44b70a80`

Read-only live smoke passed:

- `/`, `/support`, `/privacypolicy`, and `/termsofservice`: HTTP `200` and
  rendered successfully in the in-app browser
- Support email and Privacy/Terms links: present
- `LIMITLESS`, `SpyGame`, `Spy Game Zone`, `Google Analytics`, exact `gtag(`,
  Google Tag Manager, and GA measurement IDs: absent from the deployed artifact
- `gameRoomAction`, `communityAction`, `wordPackAction`,
  `notificationAction`, and `pushNotificationAction`: routes resolve and return
  the expected HTTP `401` to an unauthenticated empty request; a nonexistent
  function returns HTTP `404`
- `appleAuthBroker?action=jwks`: HTTP `200`, one valid key
- Local cross-platform room and Community contract check: passed

The full reproducible Web patch evidence remains in
`AppStoreAssets/Build-39/WebCandidate/`.

## Remaining pre-submit gates

- Perform the real authenticated two-account Web/iOS cross-platform invitation,
  room, round-transition, and Community smoke test.
- Recapture final localized App Store screenshots; the existing Build 28 set
  displays the old `1.28v` version label.
- Produce and validate the final signed Apple Distribution archive/IPA and
  verify it on a physical device.
- Complete a final read-only App Store Connect metadata/privacy audit and stop
  with Submit for Review enabled.
- Never press Submit for Review as part of this checkpoint.
