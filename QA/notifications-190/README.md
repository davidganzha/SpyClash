# Notifications and quick actions — build 190

Prepared on 19 October 2026 from baseline `dc5bd528`, on the isolated branch `davidganzha/friends-inbox-190`. Marketing version remains `1.0.3`; build version is `190` in both project definitions. This branch is a separate integration checkpoint.

## Scope

This change covers the notifications inbox, its Personal/General tabs, and accepting or declining friend requests and game invitations directly from notifications. The broader Friends screen redesign is being handled in another chat.

## Findings and changes

- A cancelled first inbox request could leave the screen permanently loading. Cancellation now restores a retryable state; returning while a cancelled request is still finishing schedules one recovery read without duplicating a successful initial load.
- Opening the inbox and refreshing its badge could request the same server snapshot twice. The page response now supplies unread counts; bursts of invalidations coalesce into a trailing refresh.
- Read receipts blocked unrelated rows and could restore stale counts or loading state. Navigation stays immediate, receipts serialize within their scope, and request ordering protects newer counts, other scopes, and account changes.
- Social notifications previously required another navigation step. Personal now shows current requests with Accept/Decline or Join game/Decline actions. Loading and failure states remain visible, and completed requests do not reappear from stale responses.
- Cached community data could hide newly received requests. Opening the screen, pulling to refresh, and push invalidations refresh the actionable source as well as the inbox. If that source is unavailable, the fallback opens Community.
- Request and invitation links open Personal notifications; ordinary Community links preserve their destination through authentication. General retains announcement links and publishing controls.
- Technical status panels and “scanning inbox” copy were replaced with compact loading, readable cards, descriptive copy, and Personal-first tabs. New interface text supports English, Russian, Spanish, and Ukrainian.

## Data and actions

No backend or schema changes are required. Action cards use the existing community snapshot and its friendship/invitation IDs; notification event IDs are never guessed to be action IDs. Generic social notification rows are replaced by these cards once that source is available. Personal pagination is omitted when it cannot reveal additional visible events.

Each request tracks its own pending action. Successful relationship changes merge into the latest snapshot rather than replacing unrelated concurrent results. Room invitations retain the existing accept → join → consume sequence, including persisted cleanup retry. The store preserves cached content during refresh and isolates responses by account and mutation/request ordering.

## Verification

The final selected test run passed **68/68 tests, 0 failures, 0 skipped**:

- `NotificationInboxModelTests`
- `NotificationInboxStoreTests`
- `Base44ClientNotificationInboxTests`
- `CommunityResponsivenessTests`
- `OnboardingTests`

Regression coverage includes cancelled initial-load reentry, overlapping successful initial loads, rapid receipt actions, account changes, stale read ordering, cross-scope rollback, invalidation bursts, routing, and reused request IDs.

Result bundle: `/Users/davidganzha/Library/Developer/XcodeBuildMCP/workspaces/SpyClash-f8b83e29e9ef/result-bundles/test_sim_2026-10-19T10-17-18-402Z_pid44209_c6073147.xcresult`.

The final `SpyClash-Supabase-Main-Candidate` / `SupabaseDebug` build succeeded and was installed and launched in the isolated `SpyClash Inbox QA 190` Simulator (`CF9C8F53-AC2A-437D-9EC9-87F61A31644F`). Installed metadata confirms build `190` and `SpyClashBackendMode=supabase-main-candidate`. Both tabs were visually inspected; preview Accept removed its row immediately and displayed success feedback. Screenshots were refreshed from this final build.

## Visual evidence and remaining validation

- [Personal, Russian](personal-ru.png)
- [General, Russian](general-ru.png)

These screenshots use a synthetic **DEBUG preview**. They demonstrate layout and the displayed actions; they do not prove real two-account delivery, physical-device behavior, or APNs delivery.

Separate physical validation remains: send and accept a friend request between two accounts, decline a request, receive and join a game invitation, retry a failed join, verify badges and push entry paths, and check reconnect/account switching.

Production services, App Store Connect, and TestFlight were not changed by this work.
