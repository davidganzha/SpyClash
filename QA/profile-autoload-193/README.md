# Community automatic profile loading — 1.0.3 (193)

Built on `2fef3178` in `davidganzha/social-integration-192`, retaining the integrated friends/inbox changes from build 192.

## Behavior

- The first 24 lightweight profile summaries load when Community opens. Find automatically requests the next page when its footer comes within 360 points of the visible screen, until the server reports the end. No normal Load More button remains.
- The list stays lazy. An 80 ms layout settling delay prevents an old footer position from downloading successive pages unnecessarily. Pagination only runs while Find is visible and the app is active, with one active request per account/search scope.
- Search uses a 320 ms debounce. Up to four queries, each with at most 240 summaries, are cached in memory for 60 seconds. Larger active lists remain browsable but are not duplicated in the query cache. Account changes clear the cache.
- Fresh reconnects preserve loaded pages. An expired first page is revalidated while existing rows remain visible; success replaces the old snapshot and restarts at the authoritative server cursor/top. Keeping an old offset after newly registered users shift the directory could otherwise skip people.
- Query/account changes and backgrounding cancel requests; late responses cannot overwrite the current scope. Profile changes received during a request take priority over its stale result.
- A failed page preserves existing rows and shows an accessible localized Retry action. Automatic failure loops are blocked. Detailed profiles/comments continue to load on demand; scrolling does not open a watcher for every person.

## Verification

Passed **37/37** focused tests with zero failures/skips. Debug and SupabaseDebug builds succeeded. The Supabase main candidate was installed and launched; bundle metadata confirms **1.0.3 (193)** and `supabase-main-candidate`. Final Simulator review confirmed initial 24 summaries, all 60 profiles reached by scrolling alone, exact SPYID search for the final profile, and cached restoration after clearing search. Screenshots: [first page](first-page-ru.jpg), [last page](last-page-ru.jpg). Results, logs and UI snapshots are recorded in [verification.json](verification.json). The dedicated DEBUG fixture provides 60 synthetic profiles in the same 24-item paging path:

`--spyclash-ui-preview --spyclash-preview-sheet=community --spyclash-preview-lang=ru --spyclash-preview-community-section=discover --spyclash-preview-directory-pagination`

The focused suites are `CommunityDirectoryLoadingTests` (15 cases) and `CommunityResponsivenessTests` (22 cases). Independent code review covered cancellation, stale cache/cursor handling, request deduplication, and the UI demand trigger.

The implementation uses geometry observation available at the existing iOS 17 deployment target. API reference: [Apple SwiftUI geometry observation](https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)).

## Scope

Client implementation and local Simulator verification only. No backend deployment, production configuration/data change, TestFlight upload, App Store operation, physical-device acceptance, or live multi-account performance claim.
