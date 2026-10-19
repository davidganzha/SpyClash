# Community migration audit — 19 October 2026

Read-only inspection of canonical Base44 app `69a0e57fa939f578082f8091` and Supabase project `bbkfsgnordtdiblgdzkg` (`spyclash-game-core`). The snapshots were captured at 10:03–10:07 UTC (11:03–11:07 London). No production records, functions, secrets, or configuration were changed. Aggregate evidence is in [migration-audit.json](migration-audit.json).

## Finding

The directory really contains eight active Supabase profiles. Five belong to migrated Base44 accounts; the other three exactly match existing cloud-test fixtures. Base44 still holds 61 current users, of whom 56 have no Supabase legacy identity link. These source accounts have not disappeared: the broad population import was never completed.

| Data | Current Base44 | Current Supabase |
|---|---:|---:|
| User/profile population | 61 users | 8 active profiles: 5 linked accounts + 3 test fixtures |
| Completed owner imports | — | 5 |
| Friendships | 5, all accepted | 0 |
| Profile comments | 3 | 0 |
| Pending social import rows | — | 0 |
| Word packs | 21 source rows | 18 provenance records imported |
| Game history | 205 source rows | 87 provenance records imported |

Supabase also contains 14 Auth users; six have no application profile. Auth-user count is not the community-directory count. Imported pack/history provenance counts are not a full cross-system content-parity assertion.

All 61 source principals are verified, have a name, and have no matching `deleting` billing lifecycle. There are 60 ordinary users and one administrator; no source email uses the checked synthetic domains. Fifteen have completed onboarding. Forty-nine have valid unique SPY IDs; twelve lack a valid SPY ID. Existing Base44 directory semantics include administrators and incomplete onboarding, then apply viewer-specific blocks; these fields do not explain the drop to eight.

## Cause and proof

1. The shipped `legacy-session` v3 verifies a single Base44 identity, reserves its UUID, and runs `prepareImport` only while that account's `import_completed` is false. `legacy-session/service.ts:72–74,116–135` and `app-services/legacy-import.ts:38–49` implement transfer at first verified login, not an all-user export.
2. Every one of the five live imports is `complete` for owner content but `social_status=deferred_verified_export_required`. The original migration document explicitly records the independent social phase as unapplied: [FULL-APP-MIGRATION.md](../../../FULL-APP-MIGRATION.md), lines 36–40; [build 172 dry run](../build172/social-import-dry-run.json) applied zero rows.
3. The deployed `app-services` v10 directory reads only active `app_private.profiles`. Its default page is 24 and maximum is 60 (`app-services/community.ts:79–96`), so eight is neither a hardcoded UI cap nor a pagination limit. Relevant live source was retrieved and inspected; these paths agree with the tracked implementation.
4. All five current links point to current Base44 users. No source friendship/comment participant is missing from the 61-user source set. The missing relationship mappings are unmigrated peers, not demonstrated orphaned or deleted identities.

## Fresh social dry run

The existing `captureLegacySocialExport` and `planLegacySocialExport` helpers were run against direct Base44 entity reads and live active verified mappings, with no writes. Two accepted friendships are ready under the existing mapping rules. Three friendships and all three comments are deferred; two deferred friendships lack one mapped endpoint and the remaining four social rows lack both endpoints. No rows were staged or applied. The checked snapshot digest is recorded in the JSON, and raw personal data was not saved.

## Concrete remediation sequence

1. Prepare a dedicated bulk directory/content importer locally. Freeze a fresh paginated source inventory and target provenance/mapping baseline; compare IDs and digests, not email ownership. Reuse every existing UUID/link/reservation and preserve later Supabase edits. Keep the 56 unmapped source identities in an explicit immutable reservation manifest until their Base44 identity is verified at login; never mark an unverified login as verified or mint sessions as part of population import.
2. Make the reserved population visible through reviewed public profiles without granting account access. Validate the first verified login adopts the reserved UUID. Preserve the 49 valid SPY IDs, collision-check and allocate the remaining twelve, reject deletion tombstones and ambiguous ownership, and retain import provenance. The current session reservation schema can support stable preassignment, but this bulk path is not yet implemented or tested.
3. Reconcile all five historical accepted friendships and three comments using the same stable mapping. The existing social helper only accepts verified legacy links, so supporting reserved dormant profiles needs an explicitly reviewed offline adapter. Preserve local decisions and blocks; generate no invitations, emails, or pushes. Audit remaining pack/history ownership and source-only content separately before calling the entire migration complete.
4. Run the importer against a local copy, test repeat execution, source drift, deletion, concurrent first login, duplicate SPY IDs, and preservation of existing Supabase edits. Produce an exact reviewed batch and rollback manifest. Test-fixture cleanup must be a separate explicit scope; the three fixtures should not be silently deleted during import.
5. Only after that package is complete, request fresh approval for its exact production target and row scope. After application, verify per-entity parity, both users' friend lists, existing-account login, and directory count. No approval was requested or inferred in this audit, and no production import package was applied.

The immediate explanation is therefore an incomplete data cutover: first-login migration was delivered, while bulk population and historical social migration remained pending.
