# SpyClash — isolated Supabase game core

This directory contains the full application staging migration, the accepted original game-core migration and the earlier reduced prototype. The full core uses the existing SpyClash gameplay screens and original room-action protocol through a separate native target. It has no production cutover switch.

Build 172's ordinary application, hybrid Base44 login/generator and Supabase application services are described in [FULL-APP-MIGRATION.md](FULL-APP-MIGRATION.md). That target is `SpyClash-Supabase-Staging`; the fixture-based build 171 target described below remains separate.

Read [FULL-CORE-VERIFICATION.md](FULL-CORE-VERIFICATION.md) for the current test evidence and remaining device/production acceptance, and [FULL-CORE-PARITY.md](FULL-CORE-PARITY.md) for the original mechanics and action contract. Passing the earlier prototype suite does not verify the full core.

## Full-core workflow

Requirements: Node.js 22+, the pinned dependencies in `package-lock.json`, and a Docker-compatible runtime. This checkout uses a dedicated Colima runtime named `spyclash-supabase`; local services bind to loopback. From this directory:

```sh
npm ci
npm run backend:start
npm run full-core:check
npm run full-core:engine-test
npm run full-core:test
```

`full-core:test` applies the full-core schema to the isolated local database, starts the real HTTP handler temporarily on `127.0.0.1:56325`, and runs independent authenticated clients against PostgreSQL and Realtime. It includes concurrent commands, dropped acknowledgements, a stopped transport, rollback and real socket recovery. It refuses cloud-linked checkouts and non-loopback fixture endpoints. Use `npm run full-core:apply` only to apply the local declarative schema while iterating; committed migrations remain the reproducible deployment source.

| Local service | Address |
|---|---|
| Supabase API/Auth/Realtime | `http://127.0.0.1:56321` |
| PostgreSQL | `127.0.0.1:56322` |
| Studio | `http://127.0.0.1:56323` |
| Mail capture | `http://127.0.0.1:56324` |
| Temporary full-core HTTP host | `http://127.0.0.1:56325` |
| Temporary application-services HTTP host | `http://127.0.0.1:56326` |

Local email confirmation/rate settings are test fixtures, not cloud configuration. Credentials, actor fixtures and raw reports stay in ignored `.local/`. Stop with `npm run backend:stop` and, if applicable, `colima stop spyclash-supabase`.

Cloud verification (existing synthetic fixtures only): `npm run full-core:cloud-test -- --check`, then `npm run full-core:cloud-test`. The exact project is allowlisted; no new users or paid resources are provisioned.

## Full-core protocol and storage

The cloud endpoint is `POST /functions/v1/full-game-core` with a verified Supabase bearer token and the original flat action payload. New mutations carry a UUID `request_id`. Capture membership, match, lobby and turn fences when creating the intent; retries keep the exact ID and payload. `update_lobby_state.expected_revision` denotes the lobby revision; the six turn/round actions use `expected_revision` for the room revision.

One PostgreSQL transaction locks the request and affected room, executes the TypeScript reducer, and commits room/membership/history/outbox/signal/receipt together. A replay returns the original receipt, which may be older than the current room. Clients reconcile an authorized snapshot after recovery. Auth verification happens before the transaction; no AI or external delivery runs while holding the room lock.

Raw room documents and receipts live in `full_game_private`, with direct client access denied. `public.full_game_room_signals` contains only room/revision metadata under membership RLS. Realtime is a refresh hint; snapshot reads establish current authorized state. Original projection rules retain candidate word pools for guessing, hide a spy's exact word until finish, and honor teammate-visibility settings. Departed players lose live access; retained eliminated spectators keep the original result/replay rights.

The full core covers both game modes, 1–3 spies, ready/roulette/server card acknowledgement, pause/deadline rules, majority request and N−S exclusion voting, guesses, departures, terminal history and replay. Server-owned word/role selection uses validated lobby settings. Saved packs and privacy-preserving leaderboard/history readers are included. See the verification document for the tested subset and remaining acceptance work.

## Actual SpyClash test app and cloud target

The actual-app target is `SpyClashSupabaseTest`, shared scheme `SpyClash-Supabase-Test`, bundle `com.spyclash.ios.supabasetest`, compile flag `SPYCLASH_SUPABASE_TEST`. It uses the original gameplay UI through `SupabaseFullGameStore` and `SupabaseGameAdapter`; it is separate from the standalone lab below.

Runtime configuration comes from `Documents/SupabaseTest/config.json`, or `LAB_CONFIG_PATH` on Simulator, using `backendURL`, `publishableKey`, synthetic `email`/`password`, and `name`. Do not commit credentials or pass server keys to an app. The compiled cloud allowlist contains only test project `spyclash-game-core` (`bbkfsgnordtdiblgdzkg`) at `https://bbkfsgnordtdiblgdzkg.supabase.co`; approved loopback origins remain for local fixtures. Physical installation and multiplayer acceptance are separate checkpoints from compilation or unit tests.

AI word generation **remains on Base44**. The build 171 synthetic test app lacks a Base44 session and displays an explicit generation-auth error; use saved/manual packs in that target. The newer full-application staging target adds verified legacy account linking and original email auth. Outbox persistence proves queued delivery work only, not external notification delivery; purchases and remote delivery for the separate TEST bundle remain capability-gated.

## Earlier reduced prototype

The original experiment remains available independently:

| Component | Legacy prototype |
|---|---|
| Backend | `supabase/schemas/game_core.sql`, private schema `game_private` |
| API | PostgREST RPC `game_command` / `game_snapshot` |
| Rules | Single spy, static word list, simplified one-round voting |
| Native app | Standalone `SpyClashGameCoreLab`, bundle `com.spyclash.gamecore.lab` |
| Local suite | `npm test`; database checks `npm run backend:verify` |
| Cloud/native runners | `scripts/cloud-test.mjs`, `scripts/native-test.mjs` |

Its fences (`membership_id`, `settings_revision`, `lobby_id`, `match_id`) and reduced snapshot shape are a different protocol. Do not use these runners or their historical counts to claim full-core coverage. Legacy build/manual-launch details are in [ios/README.md](ios/README.md); previous results are in [VERIFICATION.md](VERIFICATION.md) and [CLOUD-IOS-VERIFICATION.md](CLOUD-IOS-VERIFICATION.md).
