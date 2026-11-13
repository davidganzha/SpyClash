# Release source inventory — build 238

Baseline: `cad3156f` (build 237), reviewed 13 November 2026. This inventory used ancestry, patch comparison, actual owning source and prior integration receipts. A non-merged branch name alone does not establish a missing feature.

## Newly integrated completed UI work

| Source | Included scope | Integration constraints |
| --- | --- | --- |
| `2f93d5f8` / online intro 209 | Local presentation clock, scoped transition lifecycle, smooth card formation and prepared role reveal; 13 unit and 2 UI tests | Current authoritative room start/completion protocol remains; later FAN/gameplay code is retained. |
| `8b5ad62a` / game header 214 | Three compact host controls, personal guest exit, scoped confirmation sheets, paused-state controls; 3 UI tests | Current membership/host/room guards and pending lobby-return behavior remain. |
| `bb0fb20a` / localized suggestions | Shared searchable catalog of 50 theme ideas for online/local/editor flows | Imported only the theme component and two placeholder changes. New sheet uses game/monospaced typography and the current global invitation/toast layer. |
| `6084f6f6` / word card readability | Wider multiline word cells with 48-point minimum height | Current host, room-status and generation guards remain. |

The initial name-based inventory marked invitation banner `444d7c35` as missing. Inspection during integration showed it is superseded by build 207's `GameInvitationStore`, `SocialGameInvitationOverlay` and shared `GameInvitationOverlay`. The current flow already handles queued friend/other-player invitations, busy decisions, error feedback and account-scoped inbox actions. No second invitation state or old Radar overlay was introduced.

## Work already present

- Onboarding 163, LIMITLESS feedback/monthly compatibility 164, and gameplay/tutorial feedback from `315d6ebe` were selectively integrated by `20fb1737` (165); see `docs/releases/1.0.3-165.md`.
- Friend-first community 189 and notification actions 190 were integrated by `2fef3178` (192).
- The generation/Unity candidate 228, FAN extra deals 229 and shared word-pack library were integrated by `fb32aaa3` (230); see the build-230 QA report. Current source also contains recovery 231, names 232, Google UI removal 233 and Apple/server diagnostics 234–237.
- The separate word-pack-232 tip contains publication/TestFlight receipts; its runtime code precedes the baseline and does not require another feature merge.
- Partner fixes 13/15/16 are patch-equivalent to baseline history. Other historical game/server changes have later owning implementations and must not be restored by replacing full files.

## Explicit exclusions

- The experimental Game Center bundle `0000` is not the main App Store target.
- July website/Stripe/audio branches are historical alternate application owners, not the current iOS release baseline. Do not restore retired billing or sound assets.
- The old leave-room lease bypass `669dba79` is superseded. The current backend explicitly forbids membership-changing actions from bypassing a writer lease; only its permitted non-membership action retains that fallback.
- Bulk migration 191 and schema repair 227 are operational tools/evidence, not missing iOS features. Their earlier production operations must not be replayed as a release merge.
- Uncommitted reliability work in `9cfa`, the unfinished generation-recovery-205 working tree, and historical social-integration dirty changes are not completed release candidates. The root historical checkout also contains malformed unrelated uncommitted onboarding text. None was copied.
- Dirty build output, duplicate Swift files and temporary artifacts from old worktrees were not imported.

## Local validation at source freeze

All integrated Swift source/test files pass `swiftc -frontend -parse`; `git diff --check` passes. The theme catalog contains 50 unique IDs and 50 unique labels in each of English, Russian, Spanish and Ukrainian. These checks are not a compile or runtime acceptance claim.

Root owns the regenerated Xcode project, build number, integrated build/tests and final release record. Focused runtime suites are `OnlineIntroPresentationTests` (10), `SpyGameIntroChoreographyTests` (3), `OnlineIntroTransitionUITests` (2), `GameHeaderUITests` (3), plus existing FAN/round and room-start regressions. Previous branch test receipts remain historical until the combined candidate is tested.
