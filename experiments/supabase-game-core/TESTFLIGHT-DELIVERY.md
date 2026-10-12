# Isolated Supabase TestFlight delivery

Updated 2026-10-12. This record concerns only **SpyClash TEST**, bundle
`com.spyclash.ios.supabasetest`, App Store Connect app `6822094628`, and test
Supabase project `bbkfsgnordtdiblgdzkg`. Production SpyClash was not changed.

## Build 170: upload accepted, processing failed

The user explicitly approved registration of the separate test app, its
distribution profile, and upload of 1.0.3 (170) for David Ganzha only.

- Created explicit App ID `HDR4TDNFY5` and profile `WUL9GR6XQ5`
  (`9de6d2cc-6131-4d2f-99b9-05097dea4580`), using the existing David Ganzha
  distribution certificate in the normal login keychain.
- Created internal group `Supabase Internal QA`, ID
  `b8c0d934-1061-4795-83b0-3068a7537dee`. Its sole tester is David Ganzha;
  automatic access to all builds is disabled.
- Apple validation and upload succeeded. Delivery ID:
  `9af21416-5eda-48fa-8893-d77254296a38`.
- Subsequent official Build Uploads API read returned **FAILED**, error
  **90683**: the test target was missing `NSNearbyInteractionUsageDescription`.
  Therefore build 170 is **not available through TestFlight**.
- Exported IPA SHA256:
  `cfee5b34b6f89b67a2a36bcd6099e527a6be66f476ac569b861b74f62695247f`.

The original interface still links Nearby Interaction code even though Radar
is unavailable in the isolated test target. Apple's processing requires the
purpose string for these linked APIs. Successful upload validation alone did
not detect this omission.

## Build 171: available for internal testing

Added that purpose string to the test target and regenerated its Info.plist.
Incremented the shared project build number to **171** in both project.yml and
the generated Xcode project; marketing version remains **1.0.3**. Gameplay,
network routing, and the interface are unchanged by this packaging fix.

Release archive, distribution signature, export, test-target isolation audit,
and Apple pre-upload validation all passed. The exported IPA contains
`TFInternalTestingOnly=true`, `get-task-allow=false`, and
`beta-reports-active=true`.

IPA SHA256:
`2cca077a7d99343c63f2eb1df1b14bd412cf4e151acd5083dc380b01b077e11e`.

After the user's explicit approval for this exact build, upload completed at
22:54 UTC on 2026-10-12. Delivery/build ID:
`3743a6f4-8566-4c59-9dfa-7bc56375de96`.

Apple processing completed without errors or warnings. Read-back at 22:57 UTC
confirmed **VALID**, **INTERNAL_ONLY**, and **IN_BETA_TESTING**, with external
testing **NOT_APPLICABLE**. The build is assigned only to the existing
**Supabase Internal QA** group. Its sole tester is **David Ganzha**, whose
invitation state is **INVITED**. No public link or automatic access to all
builds is enabled. The App Store Connect UI independently showed one tester,
one build, and 1.0.3 (171) testing internally.

Sanitized verification is recorded in
`evidence/full-core-ios/build171-testflight-delivery.json`. Installation on
Ganzha and full physical gameplay acceptance are still separate pending steps.

## Physical acceptance paused pending TestFlight installation

After the phone became reachable by USB, build **170** was installed on Ganzha
and read back as 1.0.3 (170). Its existing IOS1 configuration was verified to
target the isolated Supabase project and backed up privately. Remote launch
attempts timed out; no successful live app process or new physical gameplay is
claimed here. After the user reported a black screen, iPhone Mirroring was
closed and Ganzha was normally rebooted. The user confirmed that the phone
worked normally again. No device data was reset. Device testing was stopped.

At the last UI check, both Simulator clients ran build 170 in room `JA95X8`, ID
`4fef3d5a-9f55-47e9-9a63-84bb7aa95bc3`. IOS3 is host, IOS2 is the second player;
Questions and a saved manual word pack were selected through the native UI.
The match was not started. Full mixed-client gameplay and radio-outage
acceptance remain pending.

Credentials, device configuration backups, raw role-bearing state, signing
material, archives, and IPA files are retained only in ignored `.local` paths.
