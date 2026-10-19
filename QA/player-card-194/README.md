# Rotatable lobby SpyCard — build 194

Version: **1.0.3 (194)**. Branch: `davidganzha/social-integration-192`. Baseline: `51ff73d51c3b243e08c82e463631c11507ceaf3b` (automatic directory loading).

Long-press an addressable player in a waiting/ready-voting lobby to open a centered modal over the full shell. Tap outside, the close button, or use the accessibility escape action to dismiss. Navigating away, changing accounts/room/membership, removing the target, or starting a game invalidates the selection.

The card is a physical beveled SceneKit box with front, back and metallic edge materials. The front reuses the existing public SpyCard appearance. Both sides contain public profile data only. Drag in either direction for full rotation; double-tap resets to the front. Rendering is on demand, profile textures are reused while content is unchanged, inertia stops after a short decay, and removal/backgrounding releases motion resources. Reduce Motion suppresses inertia and animated reset. VoiceOver exposes the public profile and turn/reset actions.

Friend actions honor accepted, incoming, outgoing, declined and blocked relationships. Host-only transfer and removal require confirmation and exact current actor/target scope. Host transfer preserves the roster/settings and resets readiness. Mutations are serialized within the popup flow; uncertain responses are reconciled with a bounded room read, never a blind transfer retry. Response adoption handles the former host's redacted roster projection without accepting another actor membership or an older room revision.

## Validation

Debug and SupabaseDebug builds passed. The focused Swift run passed **125/126** tests, including all **11 selection** and **3 new transfer client** tests. The sole failure is the unchanged Radar transport-count assertion; it also failed in isolation on the archived **build 193** test products. Backend validation passed **28/28 Base44** and **17/17 Supabase** tests, plus both type checks. See [verification.json](verification.json) for logs and the baseline reproduction.

Final Simulator checks used the installed `supabase-main-candidate` **1.0.3 (194)** artifact: long press, rotation through the edge/back, accessibility reset, backdrop/close dismissal, confirmed removal, and guest permissions. Friend/host transfer UI was exercised in the matching Debug fixture. UI runs use synthetic data and do not mutate remote rooms or send real friend requests. Touch double-tap reset was not directly automated because native coordinate input was unavailable; the equivalent accessibility reset was verified.

Artifacts: [front](front-ru.jpg), [back](back-ru.jpg), [guest actions](guest-ru.jpg), [rotation video](rotation.mp4).

Preview arguments:

```
--spyclash-ui-preview --spyclash-preview-tab=game --spyclash-preview-lang=ru --spyclash-preview-player-count=4 --spyclash-preview-room=waiting
```

Append `--spyclash-preview-guest` to verify that guests can inspect profiles but do not see host actions.

## Activation boundary

No production deployment was performed. The new `transfer_host` action must be deployed with the approved update to Supabase `full-game-core` and, if the Base44 route remains supported, Base44 `gameRoomAction`. Until then a live server that lacks the action cannot transfer leadership. The UI does not optimistically change the host and reports an unconfirmed action instead. Local reducer, policy, projection and client tests cover the prepared integration; live multi-device transfer remains a release validation step after the separately approved server rollout.
