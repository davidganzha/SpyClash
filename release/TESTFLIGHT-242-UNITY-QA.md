# SpyClash 1.0.4 (242) — internal Unity reward test

Build 242 uses Unity test creatives on Game ID `800429660` and placement
`BP_Rewarded_iOS`. Unity support confirmed that test ads and registered
test devices do not receive S2S redeem callbacks. This archived build
still sends an issued attempt and can remain on the bonus-confirmation
message after test playback. Its playback check cannot establish reward
delivery or credit spending.

The recovery source disables server-reward offers and account enrollment
in test-creative builds. The separate Debug SDK preview remains available
for checking ad playback.

The archive uses `SpyClash-Supabase-Public` and `SupabasePublicRelease`
with `SPYCLASH_UNITY_TEST_MODE=YES` and
`OTHER_SWIFT_FLAGS='$(inherited) -DSPYCLASH_UNITY_TESTFLIGHT_QA'`.
The compiled condition and the archived test-mode setting must agree.
The public release gate rejects this archive's test-mode setting.

The signed IPA is
`.local/testflight-unity-242/SpyClash-1.0.4-242-internal.ipa` with SHA-256
`f0192033cc3a8700a2913a6465fe69634384ae769cad6d472d507036c4cc7ff0`.
Both the app and widget have verified distribution signatures and build
number 242. The three focused configuration checks passed for a public
release, internal TestFlight and Debug compile. Apple archive validation
completed without errors.

The local archive path is recorded in
`.local/testflight-unity-242/artifact-dir.txt`. Upload that archive using
`UploadOptions-internal-only.plist` from the same directory. Confirm
Apple reports build 242 as Internal Only before assigning it to
`LIMITLESS Internal QA` (`47a13858-b43b-44a1-bf3e-285722cec320`) on
app `6793534085`. Build 238 is the App Store candidate.

For a server-confirmed reward test, install build 238 or a later live-mode
candidate on a device outside Unity's Test Devices list, with Unity's
dashboard also allowing live delivery. Use a free account and exhaust its
three daily generations. Complete one live rewarded ad, match its issued
attempt to a successful Unity callback and exactly one earned ledger row,
then spend that bonus on one completed generation. Confirm that its balance
returns to zero and that the generation request is charged to that bonus.
