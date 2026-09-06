# Local pool and word-card regression harness

Prepared from the Build 145 source checkpoint `4b6daf7`; verified in Build 146 on 2026-09-06. **512 unit tests and all three word-card UI scenarios pass.** Physical-device and live-backend acceptance remain separate.

## Final execution records

All result bundles below are under `/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/` and were inspected with `xcresulttool`.

| Run (UTC) | Result | Result bundle |
| --- | --- | --- |
| 15:59:46 | Full unit suite: **512 passed, 0 failed, 0 skipped**, including the three MembershipStore crash regressions. | `test_sim_2026-09-06T15-59-46-092Z_pid23192_b94d51f7.xcresult` |
| 15:56:01 | Word cards: **3 passed** — manual creation, editing, and generated draft; each saves and reopens the selection. The unchanged generated-draft scenario completes after the crash fix. | `test_sim_2026-09-06T15-56-01-534Z_pid23192_589603e9.xcresult` |
| 16:01:47 | Separate authentication rerun: **2 passed**, including real Google form focus and cancellation/restart. | `test_sim_2026-09-06T16-01-47-094Z_pid23192_4e35dc61.xcresult` |

The 15:56 word-card result came from a mixed run whose separate authentication assertion failed; the bundle as a whole is not reported as passed. The later authentication rerun above passed independently. Word-card UI uses preview data; Google form interaction does not establish a completed account login.

The integrating agent also confirmed a signed Build 146 installation on Ganzha, with launch blocked by the locked phone. Normal Simulator Build 146 launched as PID 69230. Neither record proves physical QR/Radar behavior or a real game.

## Confirmed additional defect

Selecting a saved local pack with 251 unique words selected all 251. Restoring the same settings limited the selected count to 200. This silently changed the words eligible for the next local game after relaunch. The editor's 200-word warning explicitly applies to **online** games; saved local packs are not subject to that limit.

`LocalWordPool.restoredCount` now preserves the selected count for saved packs and retains the 200 limit for custom AI generation. `LocalGameView` uses the shared cleaning and prefix policy for its active-pool preview and random-word selection. Saved pack data and editor cards remain complete. The five `LocalWordPoolTests` cover large saved packs, partial selections above 200, ordered normalization, generated count changes, and the existing generation limit.

## Repeatable checks for reports 4–6

| Layer | Harness | What it proves | What it does not prove |
| --- | --- | --- | --- |
| Local pool policy | `SpyClashTests/LocalWordPoolTests.swift` | The selected pool survives restore; unique words are counted before taking a prefix. | Rendering or a physical game. |
| Native persistence boundary | `SpyClashTests/WordPackPersistenceIntegrationTests.swift` | Actual `Base44Client` create/update/list JSON encoding and decoding preserve the draft's selected cards, identity of the updated pack, category fallback, and a saved 251-word pack. | Deployed backend storage, auth, contention, or LLM output. Every request is intercepted and unexpected routes fail locally. |
| Rendered editor | `SpyClashSettingsUITests/WordPackCardsUITests.swift` | Manual and fixture-AI creation plus editing expose tappable cards; cross-out/restore changes accessibility state; Save flushes unsubmitted input; closing and reopening the editor retains the selected words. Screenshots attach to the test result. | Persistence across process relaunch, a real AI request, or production save/reopen. This uses the existing explicit preview mode. |

After regenerating the Xcode project from `project.yml`, the integrating agent can run these on its selected QA Simulator. Replace `<QA_SIMULATOR_UDID>` with that already selected test target. Run no production CLI for these checks.

```sh
xcodebuild test -project SpyClash.xcodeproj -scheme SpyClash \
  -destination 'platform=iOS Simulator,id=<QA_SIMULATOR_UDID>' \
  -only-testing:SpyClashTests/LocalWordPoolTests \
  -only-testing:SpyClashTests/WordPackPersistenceIntegrationTests

xcodebuild test -project SpyClash.xcodeproj -scheme SpyClash-Settings-UI \
  -destination 'platform=iOS Simulator,id=<QA_SIMULATOR_UDID>' \
  -only-testing:SpyClashSettingsUITests/WordPackCardsUITests
```

The UI tests use their launched preview account and can alter Simulator-local preview/settings state, like the existing Settings UI suite. They should run on the dedicated QA Simulator, not a physical user device. They neither install nor run themselves merely by being present in the source tree.

## Scanner and permission lifecycle checks

`QRScannerTests` additionally exercises a decoded frame arriving after capture is paused/dismissed and foregrounding while a join is already in flight. The coordinator now rejects queued frames while capture is inactive; its controller disables that gate before scheduling asynchronous camera stop, and rechecks camera authorization before resume. AVFoundation session notifications hop to MainActor before touching the controller. These are callback/lifecycle checks, not optical or hardware acceptance.

`LocalNetworkPermissionLifecycleTests` injects a Bonjour browser and a manual clock into the actual permission coordinator. Its six scenarios cover provisional policy denial while inactive, deny→Settings return→fresh confirmed grant, stale browser generations, cancellation followed by a new request, bounded timeout/transient failure, and revocation after a cached grant. The default environment still uses the same real `NWBrowser` protocol and keeps Simulator privacy evaluation unsupported. Fake browser callbacks deliberately survive cancellation to exercise the generation fences.

```sh
xcodebuild test -project SpyClash.xcodeproj -scheme SpyClash \
  -destination 'platform=iOS Simulator,id=<QA_SIMULATOR_UDID>' \
  -only-testing:SpyClashTests/QRScannerTests \
  -only-testing:SpyClashTests/LocalNetworkPermissionLifecycleTests
```

The Radar browser, advertiser and session callbacks were also inspected: they reject replaced transport objects, and stop/rebuild detaches the old delegates. This read-only check adds no claim of physical peer discovery, ranging, or cross-device invitation delivery.

## Acceptance still requiring real clients

Use an authenticated client to create or generate a pack, cross out one word, leave another entry unsubmitted in the add-word field, save, and refresh/reopen the Arsenal. Confirm only the selected words plus the pending entry remain. Edit, restore/exclude another card, save, then reopen again. In local setup compare the active count and expanded list with the selected pack; for a saved pack larger than 200, repeat after relaunch. Real AI generation, backend contention, physical QR scanning and Radar peer/permission lifecycle retain their separate checks in the incident matrix.

## Product crash found by the first UI run

The 2026-09-06 15:45:46 UTC run passed the manual-create and edit/reopen scenarios. The generated-draft test failed waiting for the Save button because the **app crashed**, not because the test missed a control. Its crash attachment records `SIGABRT` on main with Swift's exclusivity check: `MembershipStore.snapshot.getter → hasAccess.getter → updateAIUsage(used:remaining:) → WordPackEditorSheet.performGeneration(_:)`.

`updateAIUsage` previously modified `snapshot?.aiRemaining` while evaluating `hasAccess`, which reads that same observable snapshot. It now computes access first, updates a value copy, and publishes the completed snapshot once. Three `MembershipTests` regressions exercise free/universal/paid/expired memberships, optional and negative counters, and the unresolved-account case. They pass in the final 512-unit run, and the unchanged generated-draft UI scenario passes save/reopen in the 15:56 rerun. The earlier 509-unit pass predates the added regressions.

- Result bundle: `/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-09-06T15-45-46-676Z_pid23192_5db563e7.xcresult`.
- Exported crash attachment: `/tmp/spyclash-ai-editor-ui-crash-146/A6638DC1-A4CD-475E-A2B1-4202C891C469.ips`.
