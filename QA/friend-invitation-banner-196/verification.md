# Friend invitation banner — build 196

Based on `7b0faafb` (build 195), isolated on `davidganzha/friend-invitation-banner` from the concurrent saved-action/regression work. Integration with that work must choose the next available build number.

Incoming room invitations from Community now use the same visual panel as Radar: sender's Spy Card, room code, Join and Decline. Later hides the presentation while keeping the invitation in the inbox. New invitations queue; repeated snapshots update existing cards. Joining the invited room, declined/removed invitations, and account changes clear the relevant presentation. Decisions use the existing inbox accept/join/consume pipeline, including accepted-but-not-yet-joined recovery.

## Verified locally

- `FriendRoomInvitationPresentationTests`: 6 passed, 0 failures.
- `CommunityResponsivenessTests`: 22 passed, 0 failures.
- Debug app/test build and SupabaseDebug main-candidate app build succeeded.
- Version `1.0.3 (196)` is synchronized in project.yml and the Xcode project.
- Simulator runtime app installed through the repository's signature/Keychain identity gate; backend mode `supabase-main-candidate`.
- Installed bundle SHA-256: `327736a22b00170b23edb8788a238bb75bcb1c6c79a23d266d80589601493144`.
- iPhone 17 / iOS 26.5 preview: Russian card and buttons fit; Later dismisses while attention count stays 5; Decline from the legal-document sheet dismisses all copies and decreases attention to 4; preview Join also reaches the shared action handler. Preview Join simulates resolution, not a live room entry.
- Simultaneous Radar/friend preview: Radar appears first; declining it reveals the queued friend invitation.
- `git diff --check` passed.

Screenshots: [home](home.jpg), [over an open sheet](over-sheet.jpg).

## Limits

The runtime checks used `--spyclash-ui-preview --spyclash-preview-friend-invite` with synthetic data. No real account invite, two-phone delivery/join, physical-device installation, TestFlight upload, or backend deployment was performed.

Xcode's initial compiler-discovery subprocess stalled while writing verbose diagnostics. Local verification used a temporary compiler launcher that only abbreviated discovery stderr; macro output and actual compilation arguments were preserved. This helper is not part of the app or repository.
