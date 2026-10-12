# Actual SpyClash app on physical iPhone

**Status: mixed-client gameplay and automatic recovery after a real radio outage confirmed. Final signed artifact installation and the second READY-outage verification are deferred at the user's request.** Updated 2026-10-12. Only Ganzha is available; the user has no USB cable and explicitly chose to finish device work later.

Target `SpyClashSupabaseTest`, scheme `SpyClash-Supabase-Test`, build **169**, version **1.0.3**, bundle `com.spyclash.ios.supabasetest`. Backend: isolated test project `bbkfsgnordtdiblgdzkg`. This is the actual app shell and game UI with a restricted Supabase adapter. The earlier standalone native lab has separate acceptance evidence.

## Confirmed delivery and validation

| Evidence layer | Result |
| --- | --- |
| Test-target isolation | PASS: separate bundle and URL scheme; test flag excluded from production/shared settings; no production widget dependency or privileged production entitlements |
| Final targeted native XCTest | **9/9 PASS**, run at 21:31 UTC |
| Final unsigned iPhone build | PASS |
| Normal `SpyClash` target unsigned compile | PASS; production app not launched |
| Final manual signing and `codesign` verification | PASS, existing Apple Development identity from `login.keychain` |
| Earlier updated installation on Ganzha | Verified at 21:26 UTC; actual Home/lobby rendered, synthetic actor IOS1. Initial launch PID was 22336 |
| Installation/launch of the final signed artifact after all guards | **DEFERRED**: Ganzha unavailable and USB inventory empty. Do not equate earlier build-169 installation with this final artifact |
| Post-session read-only cloud audit | **18/18 PASS**, after room revision 15: 5 tables, 10 functions, 1 replicated table, 7 rooms, 82 receipts, 12 votes; no failed checks |

Final XCTest result: `/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-10-12T21-31-18-388Z_pid52353_80097c8c.xcresult`.

The nine tests cover own-role/word projection, identity and generation mapping, match-scoped role acknowledgement, voting before the first ballot, immutable pending readiness, blocking new actions/rooms during recovery, generation-safe membership-loss clearing, and zero intercepted requests on blocked Base44 routes. These do not replace device acceptance.

Signing: identity SHA-1 `0812D17AB01C4FE7D5BD4CED2F0B0D79A24DD756`, team `3Z64QKNL54`, existing wildcard development profile `18e937c3-aaec-48a8-b11a-f9dd6e259bb4`. The user explicitly excluded the Potuzhno signing route. No signing-portal registration, App Store Connect/TestFlight operation or production backend mutation was performed.

The final signed artifact manifest is `.local/integrated-final-artifact.json`. Its executable SHA-256 is `32910280c94c40ee3522e1257a9ec2282569bbfec519294a1e7cee6d3714abe6`; debug dylib SHA-256 is `6b8e0fe3e971f75a875d6ed44b60cfed7583eb94da47a358761dae6c7a010257`. These distinguish the final artifact from earlier deliveries sharing build number 169.

## Physical and mixed-client results

Ganzha: CoreDevice ID `2EBD3C4C-977D-5DFC-B535-BAB0D382B838`, UDID `00008150-001C098C34F0401C`, iOS 26.4.2. The physical phone used IOS1; actual-app Simulator A used IOS2 and Simulator B used IOS3.

Room: `9ecd5c04-d50b-4e43-a744-52d6174fa354`. Played match: `7dd23f01-704a-47a9-8a20-9e6bfe9838d0`.

- The mixed room reached gameplay and voting. Existing-member restoration during voting was verified on Simulator B at revision 8.
- Ganzha cast a vote at revision **9**, receipt `b9656b7b-680a-4b7e-abe5-afc34f201886`. Exported phone state confirms voting, one vote and no pending command.
- The user confirmed Airplane Mode plus Wi-Fi off. Both Simulator app UIs then reached **finished, revision 11, civilians win, three votes**, with no pending commands.
- After connectivity returned, the user explicitly confirmed that the phone automatically reached **revision 11 without pressing Refresh**. This is user-confirmed physical catch-up; a post-recovery phone export was not obtained.
- The peers later reached lobby revision **15**, all three players ready, no votes and no pending commands. Phone READY committed at server revision 14. That single commit does **not** prove offline intent retention or receipt replay for the second outage: the phone became unavailable before evidence export.

This is acceptance of one physical phone plus two Simulators, not several physical iPhones. The first outage validates catch-up after peers advance. It does not establish a lost command acknowledgement on a physical client.

## Sanitized evidence and privacy

[Machine-readable verification](evidence/actual-app-iphone/verification.json) includes the final artifact hashes, test/audit results, evidence provenance, deferred gates and snapshot hashes. It contains no passwords, tokens, secret keys, private role values or words.

Seven saved snapshots were inspected: `.local/integrated-fault-start/state.json` and the six JSON files in `.local/integrated-mixed-evidence/`. Secret-bearing snapshot fields were limited to `own_role` and `own_word`; player records contained only user ID, membership ID, name, readiness and join time. No other player's role or word appeared. Finished peer snapshots showed three votes at revision 11; both final lobby snapshots showed all players ready at revision 15 and no pending commands.

The root agent ran `scripts/audit-cloud.sql` through the verified test project's Dashboard SQL editor in a read-only transaction after revision 15. All 18 privilege, RLS, function, publication and receipt/revision/vote invariant checks passed. The result is preserved in the sanitized verification JSON. This supersedes the earlier audit counts for this acceptance run.

## Reproduce the local build and manual signing

Run from the repository root using the existing authorized login-keychain identity and local wildcard profile. Do not use another application's signing assets or automatic portal registration. These commands describe local preparation; installation remains deferred.

```sh
xcodebuild -project SpyClash.xcodeproj -scheme SpyClash-Supabase-Test -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath experiments/supabase-game-core/.local/IntegratedDeviceData CODE_SIGNING_ALLOWED=NO build

SPY_TEST_APP='experiments/supabase-game-core/.local/IntegratedDeviceData/Build/Products/Debug-iphoneos/SpyClashSupabaseTest.app'
SPY_TEST_IDENTITY='0812D17AB01C4FE7D5BD4CED2F0B0D79A24DD756'
SPY_TEST_KEYCHAIN='/Users/davidganzha/Library/Keychains/login.keychain-db'
SPY_TEST_PROFILE='/Users/davidganzha/Library/Developer/Xcode/UserData/Provisioning Profiles/18e937c3-aaec-48a8-b11a-f9dd6e259bb4.mobileprovision'
SPY_TEST_ENTITLEMENTS='experiments/supabase-game-core/.local/integrated-device-entitlements.plist'

python3 - <<'PY'
import pathlib, plistlib
path = pathlib.Path('experiments/supabase-game-core/.local/integrated-device-entitlements.plist')
path.write_bytes(plistlib.dumps({
    'application-identifier': '3Z64QKNL54.com.spyclash.ios.supabasetest',
    'com.apple.developer.team-identifier': '3Z64QKNL54',
    'get-task-allow': True,
    'keychain-access-groups': ['3Z64QKNL54.com.spyclash.ios.supabasetest']
}))
PY
cp "$SPY_TEST_PROFILE" "$SPY_TEST_APP/embedded.mobileprovision"
find "$SPY_TEST_APP" -type f -name '*.dylib' -exec codesign --force --sign "$SPY_TEST_IDENTITY" --keychain "$SPY_TEST_KEYCHAIN" {} \;
codesign --force --sign "$SPY_TEST_IDENTITY" --keychain "$SPY_TEST_KEYCHAIN" --entitlements "$SPY_TEST_ENTITLEMENTS" "$SPY_TEST_APP"
codesign --verify --deep --strict "$SPY_TEST_APP"
```

The fixture belongs in the test app's `Documents/SupabaseTest/config.json`, or a Simulator-only `LAB_CONFIG_PATH`. Use only the compiled test-backend allowlist, a publishable/anon client key and a synthetic Auth account. Server/admin secrets and production sessions are rejected by this setup and must never be copied into it. Keep fixture files out of Git and exported reports. Export `Documents/Evidence` separately; this review did not open credential/actor files.

## Deferred acceptance and scope

- Install and launch the exact final signed artifact when Ganzha is reachable; record the final live PID and rendered screen.
- Export the phone's second READY-outage evidence and determine whether it retained/replayed the original request ID. Current server revision 14 alone is insufficient.
- Test a precise lost acknowledgement after commit on a physical client if the available transport permits it.
- Test several physical iPhones when additional devices are available.

The user chose to defer these physical steps because no USB cable is available. This evidence supports the separate single-spy, one-round game-core prototype. It does not establish complete original-game rule parity, production migration readiness, purchase/push/OAuth compatibility, sustained load capacity or regional outage resilience.
