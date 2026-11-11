# FAN server synchronization — deployed as v16

## Confirmed cause

The released TestFlight 1.0.4 (230) client sends all five FAN probabilities. At diagnosis, the live `full-game-core` function in project `bbkfsgnordtdiblgdzkg` was v15, updated 2026-11-05, with FAN v1 settings. Its canonicalizer retains only the original two fields and silently drops `fan_split_words_chance`, `fan_unique_words_chance`, and `fan_lone_civilian_chance`.

The client accepts the advanced lobby revision and then displays the returned old settings. This is a server/client version mismatch, not a missing field in the current local save path.

[Local reproduction](settings-roundtrip.json) runs the exact downloaded live source and the prepared candidate against the same input: live drops all three fields; the candidate preserves all five after JSON serialization and reading the lobby back.

## Approved production operation

Replaced only Supabase Edge Function `full-game-core` in `spyclash-game-core` (`bbkfsgnordtdiblgdzkg`), preserving `verify_jwt=true`, entrypoint `full-game-core/index.ts`, and import map `full-game-core/deno.json`.

The [manifest](deployment-manifest.json) freezes all 44 uploaded files; the [patch](server-update.patch) shows the 10 changed game-engine files. The candidate starts from live v15 and overlays only the FAN/game-engine changes already integrated in client build 230 (`8e26385c`). All 34 other live files, including bundled membership/billing dependencies, are byte-for-byte preserved. No app-services deployment, shared-library change, secret change, schema migration, TestFlight upload, or client rebuild is included.

This updates older FAN v1 behavior to the already implemented v2 draw flow and adds v3 personal words/new deals. It retains the user-selected fresh defaults of 2% for each of five surprises and 90% ordinary play, preserving explicit legacy settings.

## Verification

- 38 tests passed against the **assembled candidate**, not only repository source: 14 engine, 21 FAN, 3 leaderboard. See [test log](candidate-tests.log).
- Candidate index and all runtime imports typechecked. See [typecheck](candidate-typecheck.log).
- Local roundtrip confirmed all five probabilities survive saving and reading; independent audit covered host/guest projection and repeat requests.
- Read-only production schema check confirmed room state is JSONB. No migration is required.
- User approved this exact production deployment with “да” in this chat. Function v16 became ACTIVE at 2026-11-11 20:48:44 UTC. All 44 returned source files exactly match the approved candidate; authentication remains required (unauthenticated request returns 401). No authenticated test-room write or real-device multiplayer check was performed. See [deployment receipt](deployment-receipt.json).

Local candidate/rollback material: `/private/tmp/spyclash-fan-server-sync-20261111/{candidate,live}`. Immediately before publishing, live v15 and its bundle hash matched the frozen baseline. Exactly the 44 manifest files were uploaded; the validation-generated deno.lock was excluded. The subsequent live-source fetch confirmed v16, ACTIVE, and an exact match for all uploaded files.

Fresh approval in this chat was obtained immediately before the production operation, as specified by AGENTS.md. Build 230 already has the client behavior; this checkpoint only adds QA/deployment records, so no application build number was changed.
