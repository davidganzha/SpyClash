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

# Apple signing identity selection

- The user explicitly forbids `PotuzhnoSigning` / `potuzhno-signing` and Potuzhno signing profiles. Do not use, unlock, or request passwords or keys for them, including as a fallback.
- Use an existing, accessible certificate and private key from an allowed keychain, with a provisioning profile matching the target app and signing purpose. The default keychain search list is not an allowlist.
- Check candidate identities in explicitly allowed keychains before any signing attempt. A visible certificate alone does not prove its private key is accessible; do not fall back to another keychain implicitly.
- Current approved development signer, verified on 2026-11-19: Apple Development SHA-1 `AFAB62D325B968A3B130E1807A483F6B29744687` in `~/Library/Keychains/login.keychain-db`, team `3Z64QKNL54`. Use an explicit keychain and exact fingerprint, then verify current availability. See `release/SIGNING-RECOVERY-20261119.md` for the matching profiles and verification scope.
- Previously verified SpyClash identities are Apple Development SHA-1 `0812D17AB01C4FE7D5BD4CED2F0B0D79A24DD756` for device builds and Apple Distribution SHA-1 `B5E2C6B39C13237FBB0F3B8DB583951E9F06DC87` for distribution, team `3Z64QKNL54`. Recheck current availability and profile compatibility rather than assuming historical access still works.
- Do not recreate or revoke certificates, reset or unlock old keychains, or change the user's keychain search list merely because an identity is unavailable. Report the exact access issue after checking existing permitted signing routes.
