# Production safety

- Never deploy, publish, promote, release, or otherwise mutate a production environment without explicit approval in the current chat immediately before the production action.
- This prohibition includes App Store Connect submission, App Review submission, TestFlight promotion, App Store release, Base44 production deploy/publish, production Stripe changes, production webhook changes, and production secret/configuration changes.
- General instructions such as "continue", "finish", "prepare for release", or approval given in another chat do not authorize a production action.
- Agents may inspect, audit, prepare code and metadata, build locally, and run tests or dry runs that do not mutate production.
- Before any authorized production action, state the exact target and operation and obtain a fresh, unambiguous confirmation from the user.

# Versioning and GitHub checkpoints

- Every completed addition or modification to SpyClash code, UI, backend logic, configuration, or shipped content must increment `CURRENT_PROJECT_VERSION` before handoff.
- Keep the version values in `project.yml` and `SpyClash.xcodeproj/project.pbxproj` synchronized. Change `MARKETING_VERSION` only for an intentional release-version change requested by the user or required by the release plan.
- Commit each completed, verified change as a scoped Git commit and push that commit to the current GitHub branch unless the user explicitly asks not to push.
- Never mix unrelated pre-existing worktree changes into the checkpoint commit. A GitHub push is not authorization for any production action listed above.
