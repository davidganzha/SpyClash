# Friends and notifications integration — build 192

Combined on 19 October 2026 in `davidganzha/social-integration-192`.

## Source

- Baseline `a32c8e9ce154a7cde52f5d3b3c2ba63de47bb2fc`: current Supabase main candidate with immediate Radar invitation dispatch.
- Inbox `493a1890d8c4590964e3d0d2a3f1014be45316ba`: Personal/General notifications, direct accept/decline/join, guarded reconciliation and read receipts.
- Friends `96067d209f09819ae00265addbe78f7cba97da07`: Friends-first directory, separate requests, inline actions and named removal confirmation.

Both source commits were applied together; version-only conflicts resolved to `1.0.3 (192)` in both project definitions. Historical QA records retain their original build numbers.

## Integration

The combined preview uses one shared social state, so accepting a request from either screen updates the other screen and handled requests stay resolved across navigation. Real account flows retain their existing authenticated reads, scoped optimistic changes, and account guards.

## Verification

- Passed 91/91 selected XCTest cases, zero failures or skips, in Debug. Includes notification models/store/transport, community responsiveness, navigation, onboarding routes, and the four immediate Radar dispatch cases.
- Supabase main candidate / SupabaseDebug build succeeded, installed and launched on the isolated Simulator, renamed `SpyClash Social 192` (`CF9C8F53-AC2A-437D-9EC9-87F61A31644F`). Installed metadata confirms `1.0.3 (192)` and `SpyClashBackendMode=supabase-main-candidate`.
- Visually inspected Russian Personal, General and Friends screens. Accepted Signal in Personal, verified Signal appears as the second friend, returned to Personal and verified the request stays absent. Declined Cipher's room invitation from Friends, returned to Personal and verified no pending requests remain.
- Restarted the preview on Friends with original sample requests for user review. Final live process: `86089`.
- Independent production integration review found no merge-introduced blockers. Both source and staged whitespace checks passed.
- Exact test/build artifacts, UI captures and launch evidence: [verification.json](verification.json).

Screenshots: [Friends](friends-ru.jpg), [Personal](personal-ru.jpg), [General](general-ru.jpg), [friend after acceptance](friends-after-accept-ru.jpg), [inbox after returning](personal-after-return-ru.jpg), [inbox after declining in Friends](personal-after-community-decline-ru.jpg).

No production deployment or data migration is part of this integration. Synthetic Simulator previews demonstrate interface and local state behavior, not physical-device or two-account network delivery.
