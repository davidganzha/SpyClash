# Community friendship UI — build 189

Community now opens on Friends. Incoming requests and room invitations remain visible, while Requests separates received and sent requests and Find supports adding or accepting directly from readable player rows. Own SPY ID can be copied. Removal requires a named confirmation; report/block remain in the More menu. The directory count explicitly describes shown profiles. Section changes return to the top without resetting network state.

The existing Supabase transport, optimistic relationship mutations, account guards and realtime reconciliation remain in place. This change does not import or alter backend data. See [the live migration audit](MIGRATION-AUDIT.md) for the separate incomplete data transfer.

## Verification

- SupabaseDebug build succeeded; final focused XCTest run passed 28/28 (16 relationship/responsiveness and 12 navigation tests).
- Installed and launched `1.0.3 (189)`, `com.spyclash.ios`, backend mode `supabase-main-candidate`, in SpyClash Supabase Lab C on iOS 26.5.
- Inspected rendered Russian, English, Ukrainian and Spanish screens. Screenshots use synthetic preview profiles only.
- Exercised add, sent-request navigation, cancel, accept, named removal confirmation, removal, accepted profile, friend search by six digits, empty state, and section scroll restoration. Details and source hashes: [verification.json](verification.json).
- Independent code review and `git diff --check` passed. The first XcodeBuildMCP invocation stalled at a compiler environment probe; only that build was stopped. A shell build and both focused test runs then passed.

## Screenshots

- [Friends, Russian](friends-ru.jpg)
- [Find and inline actions, Russian](find-actions-ru.jpg)
- [Requests, English](requests-en.jpg)
- [Requests after returning from scrolled Find, Spanish](requests-scroll-restored-es.jpg)
- [Empty friends, Ukrainian](empty-uk.jpg)
- [Remove confirmation, Russian](remove-confirmation-ru.jpg)
- [Full profile, Russian](profile-ru.jpg)

The installed pre-change baseline was build 187; its screenshot is [community-before187.jpg](community-before187.jpg). Source work began from build 188 commit `dc5bd528`. Concurrent unrelated Radar/Inbox work was kept outside this checkpoint by using branch `davidganzha/community-friendship-189` in an isolated worktree.

Production data and backend deployments were untouched. This local Simulator preview is not a TestFlight delivery or physical-device/two-account acceptance. The complete bulk account/social importer still needs implementation and validation as described in the migration audit.
