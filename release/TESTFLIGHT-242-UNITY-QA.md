# SpyClash 1.0.4 (242) — internal Unity reward test

Build 242 uses the same Game Center, Supabase and server-confirmed reward
flow as the App Store candidate, with Unity test creatives on Game ID
`800429660` and placement `BP_Rewarded_iOS`. The build still sends the
server-issued attempt to Unity and waits for the backend to confirm the
reward.

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

On the iPhone, use a free account with three daily generations remaining.
After using the three, complete one test ad and check whether the app
receives one server-confirmed generation. Spend that bonus once and
record the state of the next request. Test SDK playback, callback delivery
and credit balance are separately verifiable. Playback alone establishes
only the display and completion of the creative.
