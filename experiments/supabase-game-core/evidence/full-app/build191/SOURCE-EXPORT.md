# Canonical Base44 source archive

The private archive captures **1,148 rows across all 26 live entities**, including the built-in User principal. Every row was read twice using stable-ID pagination and both complete scans have matching per-entity digests. The 27th tracked schema, `AccountDeletionReceipt`, was independently confirmed absent on the source; it is distinguished from a deployed empty table.

The independent authenticated `GET /api/apps/69a0e57fa939f578082f8091/entity-schemas` inventory returned exactly the same 26 entity names. Two complete schema responses also match. This endpoint was identified in the installed Base44 CLI's `core/resources/entity/api.ts`; only GET was used. No eject, clone, schema mutation, function invocation, or data mutation occurred.

- [Source counts and content digests](source-summary.json)
- [Independent remote schema inventory and asset audit](remote-schema-inventory.json)
- [Owner/reference eligibility](source-eligibility.json)

The raw rows, original full schema responses, and private logs are confined to ignored `.local/bulk-migration/`. The directory is mode `0700`; the archive and schema responses are mode `0600`. They contain private account information and encrypted provider credentials and must not be committed or copied into public evidence.

Archive: `experiments/supabase-game-core/.local/bulk-migration/source-snapshot.json`.
Canonical content digest: `7a51624a000781dd999d434159361e48485afef11fc710b51df0477c80d392eb`.

The snapshot contract is `{version, source:{origin,appID}, capturedAt, verifiedAt, entities, inventory, sourceSchemas, consistency, digest}`. `entities` maps each known entity to its full original rows. `inventory` records availability, row count, both content digests, and the tracked schema digest. The companion private `remote-entity-inventory.json` and `remote-entity-inventory-verified.json` preserve the authoritative live schemas; `sourceSchemas` in the main archive is the tracked schema baseline. The complete source archive and remote schema sidecars together preserve both representations without overwriting either.

Public progress can be preserved for 61 current source users. There are 49 valid unique SPY IDs and 12 absent/invalid IDs. History has 135 current stable owners, 65 rows owned only through unique legacy email, and five rows without a current owner. Two packs retain stable owner IDs absent from the current source User table. Those rows remain in the archive; ownership must not be reassigned or deleted accounts recreated automatically.

All User and WordPack values were scanned recursively for HTTP(S) asset references. There are **zero URLs**, so this snapshot has no referenced Base44-hosted avatars/files in those entities requiring a separate media copy. This statement does not assert that the Base44 file store contains no unreferenced files.

`source-export.ts` has ten passing tests: complete bounded pagination and raw fidelity, content/deletion drift, repeated IDs, incomplete inventory, explicit row bounds, sanitized errors, absent-vs-empty schemas, schema availability drift, and fresh-capture path validation. The CLI wrapper type-checks. It suppresses raw SDK error logging and emits only an aggregate result. The exporter refuses to overwrite an existing archive.

For a separate fresh read, set `BULK_MIGRATION_CAPTURE=fresh-<unique-name>` when invoking the existing authenticated source-export CLI wrapper. It writes below `.local/bulk-migration/fresh-<unique-name>/`; the original sealed snapshot is preserved. The capture name permits only lowercase letters, digits, underscores, and hyphens and cannot escape the private directory.

Immediately after that read, run `schema-inventory.ts <fresh-folder>` from the experiment directory. It uses the existing local Base44 CLI authentication and performs only two GET requests to the independently identified schema route. Both complete raw responses and a snapshot-bound `remote-schema-inventory.json` are stored in that same private directory. Existing outputs are never replaced. Five tests cover matching double reads, exact entity inventory, schema drift, stale source evidence, and sanitized provider errors.

Then run the offline `attestation.ts <sealed-job-folder> <fresh-folder>`. It checks the sealed operator packet, all entity content and both entity digests, authoritative remote schema names and content, and fresh timestamps. It emits private `source-attestation.sql` only when the original content still matches. The SQL contains the literal proof time, expires after 60 seconds, requires completed Auth provisioning and no active worker lease, and requires the fresh capture to have started after the job's last provisioning update. An unchanged proof cannot be replayed later to renew its validity. Exactly one returned row is required when an authorized operator eventually applies that SQL. Thirteen tests cover valid proofs, source/schema drift, incomplete inventories, stale/future evidence, sealed-packet mismatch, and SQL metadata restrictions. These helpers have not applied SQL or mutated either remote provider.

The scans are not a cross-entity database transaction. Re-read source data and schema inventory immediately before a reviewed production application; compare their digests to the approved package and stop on drift. This archive is evidence and preparation, not a completed target import.
