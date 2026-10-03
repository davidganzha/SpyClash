# Partner feedback — 1.0.2 (163)

Source baseline: build 161, `d327b0db08c8c45e5edfb492453da7b57b304c6d`.
Branch: `davidganzha/partner-seven-fixes-162`.

## Seven requested changes

1. **Persistent or mislabeled invitations:** notification event type determines the label and destination. Resolved friendship requests and non-actionable room invitations disappear from the Inbox and unread counts. Joining by invitation, QR, or code durably resolves matching room invitations; leaving cannot revive them. Consume/decline also cancels the notification projection before deleting its source. Re-inviting creates a fresh generation and timestamp.
2. **Lobby player long press:** opens the existing Community profile with SpyCard, friendship actions and reporting. Current lobby participants can receive public profile IDs; private membership IDs remain host-only. Departed players and outsiders receive no new identifiers.
3. **LIMITLESS copy:** explicitly includes creating and saving an unlimited number of word packs in English, Russian, Spanish and Ukrainian.
4. **Arsenal word editing:** word cards remove words instead of toggling exclusions. The count and saved payload use the remaining words. At least two unique words are required. Gameplay selection controls are unchanged.
5. **Radar permissions:** denied Local Network or Nearby Interaction hides Radar entry points. Unknown/rechecking local access hides the directory and blocks transport; revocation clears peers and incoming invitations. Foreground Local Network recovery requires a fresh grant. Known NI denial is retained until an explicit retry through Settings. Unsupported hardware retains its directory fallback.
6. **Invitation latency:** independent validation reads run in two parallel stages instead of four serial stages. Native invitation acknowledgement does not wait for a full Community refresh. Durable push handling and retries remain intact. Actual phone-to-phone/APNs latency has not been measured and is not bounded by this change.
7. **Host return to lobby:** guests have no return button. One host action resets the shared active room with participant lifecycle leases. Authorization, match generation and deadline are rechecked on CAS retries. Replay and finished-match handling remain separate. Installed hosts that send the legacy `vote=false` payload can also return everyone; guests remain unauthorized.

## Validation

- Simulator build succeeded; built bundle reports version **1.0.2 (162)**.
- Full iOS unit/integration suite: **580 passed**.
- Six relevant UI scenarios passed: create/edit/generate pack, remove words, save and reopen; Local Network denial; Nearby Interaction denial; long press into the correct player profile with relationship/report actions. The first UI run passed five cases; the long-press test was corrected to scroll above the fixed bottom controls and passed separately.
- Combined `communityAction`, `notificationAction`, and `gameRoomAction` tests: **546 passed** after the deployment compatibility check.
- Deno entrypoint type checks, function-bundle isolation, formatting and `git diff --check` passed.
- Independent review checked invitation pagination, event renewal, duplicate source handling, cleanup leases, host authorization and match-reset safety.

Reproduction commands:

```sh
/Users/davidganzha/.deno/bin/deno test --allow-read --allow-env \
  base44/functions/communityAction \
  base44/functions/notificationAction \
  base44/functions/gameRoomAction
```

Xcode unit scheme: `SpyClash`. UI scheme: `SpyClash-Settings-UI`, selecting `WordPackCardsUITests` and `LobbyFeedbackUITests`.

Build 163 adds backend compatibility for the installed host payload; the Simulator and iOS test evidence above belongs to Build 162, whose native behavior is unchanged.

## Delivery boundary

The three backend functions were deployed with explicit user approval on 3 October 2026. [Deployment receipt and exact runtime verification](2026-10-03-partner-feedback-deployment.md). All 81 target runtime files matched the candidate; the other 14 functions were unchanged. The separately deployed 3-second intro was preserved.

No App Store/TestFlight upload or physical-device installation was performed. The client changes still require native app delivery. Two-phone acceptance remains necessary for real invitation timing, denied-permission recovery and Nearby Interaction ranging. The separate Web checkout was not included in this native iOS change.
