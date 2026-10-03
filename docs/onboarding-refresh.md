# Onboarding refresh — build 163

Base: `d327b0db08c8c45e5edfb492453da7b57b304c6d` (build 161), branch `davidganzha/onboarding-refresh`.

## Behavior

- Keep the waving-hand introduction and language selection.
- Explain the secret word and spy with two role cards, then introduce nearby Radar.
- Only Local Network is requested in onboarding. Preserve its existing denial/settings/retry and unsupported-device behavior. No separate setup-complete page.
- Keep onboarding contract version 2 so existing v2 accounts are not forced through the new presentation. Preserve remote and pending-v1 acquisition answers during the Radar upgrade.
- Camera remains requested by QR/radar use. Push authorization is offered explicitly in Notifications.
- Ask “Where did you first hear about SpyClash?” after three distinct completed local/online games, when the player returns to idle Home. Results, active rooms, QR, tutorials and incoming Radar/join routes take priority.
- Dismissal is remembered per account on this device; no fabricated `other` answer. Answers remain pending locally until the existing partial User update confirms them. A successful response updates only the acquisition field in local state.
- Survey progress and dismissal are device-local. A synchronized answer suppresses the survey across devices. The sample represents players who have completed three games, not every installation.

No backend schema/function changes or deployment is required by this branch.

## Parallel branches — inspected 2026-10-03

| Work | Observed base / branch | Integration notes |
| --- | --- | --- |
| Lobby, invitations, Radar | `d327b0db`, `davidganzha/partner-seven-fixes-162` | Its Local Network callback and Radar tests are separate from the nearby-only onboarding order. Read-only `git apply --check` of overlapping Swift changes passed against this worktree. Keep both sets of hunks. |
| Gameplay, guide, word pools | `f3469363`, `davidganzha/partner-gameplay-fixes` | Shares HomeView, LocalGameView and Base44Client. Home modifier is isolated; local completion hook must remain alongside gameplay changes. Direct patch checks failed in LocalGameView/Base44Client because this branch starts from a different, older release line; port targeted hunks onto build 161+, not complete files. |
| Google/auth/generation | `e3a59d16`, observed in worktree `9cfa` | Auth edits in AppState use the old July layout. Direct patch check fails against the newer layout. Port those changes into current auth methods; retain the onboarding/survey account-change hooks. |

These are snapshots of neighboring changes inspected during this task, not a claim that those branches have been merged or validated here. All edits in this branch stay inside its own worktree. Regenerate the Xcode project from `project.yml` and choose a fresh build number when combining branches, rather than accepting generated-file/version conflicts wholesale.

## Validation

- Debug Simulator build succeeded after the final UI edits. Installed bundle independently reports build 163; marketing version remains 1.0.2.
- 90 targeted XCTest cases passed with no failures or skips: onboarding submission and legacy-source preservation, Local Network mapping/lifecycle, survey persistence and AppState integration, and notification inbox models.
- `scripts/check-ios-release-bundle.sh --simulator` passed for the built app. This is a Simulator artifact check, not a signing or App Store validation.
- Manually exercised the Russian language → roles → Radar → completion animation → Home flow in the dedicated iPhone 17 / iOS 26.5 Simulator. Also checked the deferred survey presentation/skip path and maximum accessibility text size; the Radar explanation scrolls above the fixed action.
- A second code review confirmed completion survives onboarding-view disappearance, pending legacy acquisition answers are retained, and incoming Radar/join routes take priority over the survey. `git diff --check` is clean.

Physical iPhone Local Network authorization, two-device nearby discovery and real push delivery were not tested. No production deployment or App Store action was performed.
