# SpyClash 1.0 (40) — local release evidence

Prepared on 28 July 2026 for Apple ID `6793534085`, team
`David Ganzha (3Z64QKNL54)`, bundle ID `com.spyclash.ios`, Base44 app
`69a0e57fa939f578082f8091`, and `https://spyclash.com`.

This is a local checkpoint only. Build 40 is not uploaded or selected in App
Store Connect. It is not submitted to App Review, promoted through TestFlight,
or released. The Web candidate is not deployed.

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
complete Base44 suite (`470 passed`, `0 failed`). No recovery deployment was
performed.

Partial-attempt postflight evidence is stored locally at
`.base44-cutover/evidence/notification-step-b-functions/20260728T113708Z-60712/postflight.json`.

## Interactive Web candidate

- Candidate commit: `fb0860f0a603f5020ca059f48ae930d213ae0ce9`
- Dist files: `6`
- `DIST_INVENTORY_SHA256`:
  `c02535dfd3e7d1c54f8bbdecb5e210cb2c209dc822b10e66975709e7d0b3bb19`
- Public support email: `yanushevych.mr@gmail.com`
- Deployment state: not deployed

The full reproducible Web patch evidence remains in
`AppStoreAssets/Build-39/WebCandidate/`.

## Remaining pre-submit gates

- Obtain fresh authorization for the new push-only recovery digest, deploy only
  that function, and require exact postflight.
- Only after recovery passes, separately deploy the exact six-file Web artifact
  and perform authenticated Web/iOS cross-platform smoke testing.
- Recapture final localized App Store screenshots; the existing Build 28 set
  displays the old `1.28v` version label.
- Produce and validate the final signed Apple Distribution archive/IPA and
  verify it on a physical device.
- Complete a final read-only App Store Connect metadata/privacy audit and stop
  with Submit for Review enabled.
- Never press Submit for Review as part of this checkpoint.
