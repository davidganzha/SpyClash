# SpyClash 1.0.3 (173) — main application preparation

This checkpoint prepares the original iOS application for the hybrid backend. It does not upload, publish, migrate production, change Apple provider settings, or authorize those actions.

## Build identities

| Scheme | Bundle | Backend | Distribution status |
|---|---|---|---|
| `SpyClash` / Release | `com.spyclash.ios` | Existing Base44 | Existing release configuration retained until cutover approval. |
| `SpyClash-Supabase-Main-Candidate` | `com.spyclash.ios` | Isolated `bbkfsgnordtdiblgdzkg` | Local preparation; release gate deliberately refuses distribution. |
| `SpyClash-Supabase-Staging` | `com.spyclash.ios.supabasetest` | Isolated `bbkfsgnordtdiblgdzkg` | Separate TEST application; no new upload authorized. |

The main candidate uses the ordinary UI, original widget and `spyclash` URL scheme. Its build configuration is immutable; no remote flag can switch an installed production binary to the test database. Apple/Google buttons reuse the existing Base44 provider integration. Billing, remote push and full account deletion require explicit matching server readiness before their native flags are enabled.

App Store Connect was inspected read-only at 2026-10-13 01:14 UTC: original app `6793534085`, bundle `com.spyclash.ios`, version 1.0.2 is `READY_FOR_SALE`. The intended next marketing version remains 1.0.3. No 1.0.3 App Store version was created or submitted by this preparation.

## Authentication and account continuity

- Preserve Base44 email/password, six-digit verification, resend and recovery, plus the existing Apple/Google brokers. No SMTP or new paid authentication service is introduced.
- Exchange only a server-verified Base44 identity into its immutable Supabase mapping; matching contact emails never link accounts.
- Migrate a saved original-app credential only after a verified exchange and ownership check. Persist the credential pair before clearing its old slot. Cancellation, logout and a newer sign-in fence delayed responses.
- Revalidate an expired session once and replay the exact saved operation. Explicitly revoked sessions do not silently sign back in.
- Isolate Radar discovery between the Base44 and Supabase backends; native room links use the receiving application's scheme.
- Existing-account password login on Ganzha in build 172 was verified against source: matching profile/SPY ID, 8 history rows and zero owned packs. See [acceptance evidence](../experiments/supabase-game-core/evidence/full-app/build172/account-import-acceptance.json).
- Google in the main Simulator candidate opens the real Google sign-in page for SpyClash. Full Apple/Google completion and account matching on a device remain acceptance steps; neither compilation nor this provider page proves them.

## Free-plan deployment choice

Read-only inventory on 2026-10-13 found two active projects in the organization: SpyClash and GATEBREAK; Project1 is inactive. [Supabase Free permits two active projects](https://supabase.com/pricing). No third project, upgrade, pause or deletion was requested or performed. The SpyClash database occupied about 14.8 MB at the read-back; this is database size, not a load, egress or Realtime quota guarantee.

The current SpyClash project is still a test environment: 10 Auth users, one verified real legacy account, 15 rooms, 20 history rows and 2 packs at the read-back. It must not be described as a clean production database. A zero-additional-service-cost cutover can be prepared around this existing project, but requires explicit approval of its new production role, a backup, an exact reviewed fixture inventory and a data preservation plan. GATEBREAK must not be paused to free capacity without a separate request.

## Concrete release sequence

1. Finish local verification and review the [auth/deletion preparation](../experiments/supabase-game-core/AUTH-REVIEW-173.md) and [billing/APNs preparation](../experiments/supabase-game-core/base44-prepared/README.md). Prepare only the named canonical Base44 changes; re-pull and compare their live sources immediately before packaging.
2. Approve the production backend target and exact migration/configuration operations. Preserve the real account and its imported content; identify fixtures by verified provenance, never by broad email/name patterns. Export and reconcile legacy friendships/comments with verified identity mappings. Keep unmatched participants deferred and report them.
3. Apply and verify the matching Supabase migrations/functions, provider bridges and maintenance delivery/recovery scheduling. Keep credentials server-side; prepare separate random relay/recovery secrets without exposing them to the app or Git.
4. Verify main-bundle Apple and Google login, same-account password access, recovery, restore after relaunch, account switch/logout, purchase restore/current weekly product, notification delivery and Live Activities. Verify account deletion including a lost acknowledgement with a disposable account. Source tests do not substitute for these live integrations.
5. Prepare the explicit client transition: older Base44 clients and the web application still use Base44 rooms. The hybrid QR control exposes iOS only; main Supabase room links must not claim browser compatibility until the web entry is migrated or a version-aware handoff is prepared. Keep old clients from appearing as compatible Radar peers.
6. Update the main release configuration to the approved production backend/capabilities; remove the candidate-only release block only when the preceding gates have evidence. Build a fresh device archive, sign it, run the signed release bundle gate, inspect its actual backend identity, widget, entitlements and absence of test fixtures/secrets.
7. Present the exact main-app TestFlight audience/build for approval. After accepted device checks, prepare App Store 1.0.3 metadata and reviewer access; obtain separate approval before submission or release.

An App Store rollback is not an immediate backend rollback. Once clients write new rooms, packs or profile changes to Supabase, reverting to Base44 alone would omit those writes. Retain provenance, export/reconciliation tools and version-specific backend routing; do not promise an automatic bidirectional rollback.

## Local verification completed

The final main candidate built in both SupabaseDebug and SupabaseRelease; SupabaseDebug was installed and opened the original welcome/auth UI on Simulator. The ordinary Release configuration also built with the original Base44 mode, widget build 173, and no candidate configuration/allowlist resources. Its Simulator bundle gate passed; the main Supabase candidate was rejected by the same gate as intended. This does not verify a signed device archive.

Native regression passed 105/105 in the original target and 41/41 in staging. The application backend passed 75/75, the game core 14/14, Base44 deletion 34/34, and release-gate fixtures 44/44. Backend checks used local PostgreSQL/Auth and mocked external provider responses where required. The hybrid build retains 27 unreachable-legacy-branch compiler warnings, with no build errors. Detailed artifacts and acceptance limits: [build 173 verification](../experiments/supabase-game-core/evidence/full-app/build173/verification.json).

## Draft release text (not published)

English: Improved game synchronization and recovery after connection interruptions. More reliable sign-in and session restoration.

Russian: Улучшена синхронизация игры и восстановление после обрывов связи. Повышена надёжность входа и восстановления сессии.

Reviewer notes should identify the unchanged weekly subscription and its actual rollout state, provide a working review account through App Store Connect's private fields, explain account deletion, and describe the tested multiplayer flow. Do not claim provider login, purchase restore or deletion acceptance until verified. Public privacy disclosures must match the final Supabase/Base44 data routing before submission; local copy preparation is not publication.
