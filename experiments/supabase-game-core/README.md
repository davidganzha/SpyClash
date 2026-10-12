# SpyClash — isolated Supabase game core

An executable backend experiment for concurrent room commands and recovery after network failures, with a standalone native iOS test app. It runs real Supabase Auth, PostgREST, PostgreSQL and Realtime locally or in the separately allowlisted cloud test project. It uses synthetic accounts and never connects to Base44.

This is a **single-spy, single-round prototype**. The separate SwiftUI lab app exercises this core; the production SpyClash app has not been migrated. Apple/Google login, account migration, purchases, AI generation, notifications, full game rules/timers and multi-spy matches remain outside this experiment.

## Run

Requirements: Node.js 22+, a Docker-compatible runtime and sufficient disk space for the local Supabase images. Packages and the Supabase CLI are pinned in `package-lock.json`.

On this Mac, the dedicated runtime was created with:

```sh
brew install colima docker
colima start spyclash-supabase --cpu 4 --memory 6 --disk 30 --runtime docker --vm-type vz --activate=false --ssh-config=false
```

From this directory:

```sh
npm ci
npm run backend:start
npm test
npm run backend:verify
npm run backend:status
```

`backend:start` applies committed migrations automatically on a fresh database. `backend:apply` is a developer-only helper for applying the declarative source to this local test database while iterating; do not use it as a replacement for versioned migrations.

The local runner discovers credentials in memory through `supabase status`. Local tests refuse non-loopback endpoints, and the runner refuses cloud-linked checkouts and unexpected local ports. Credentials, download logs and raw reports stay in ignored `.local/`. Cloud tests use a separate explicit entry point and an exact project allowlist. The package has no cloud deployment command.

The runner creates a dedicated Docker bridge with `host_binding_ipv4=127.0.0.1`, so the local fixture services are not published to the LAN. It also checks this option before starting the stack.

| Service | Address |
| --- | --- |
| API / Auth / Realtime | http://127.0.0.1:56321 |
| Studio | http://127.0.0.1:56323 |
| PostgreSQL | 127.0.0.1:56322 |
| Local mail capture | http://127.0.0.1:56324 |

Email confirmation is disabled and signup limits are raised **only in this local fixture configuration**. Do not publish it or use real user data.

To stop while preserving local test data:

```sh
npm run backend:stop
colima stop spyclash-supabase
```

## Separate cloud test project and native iOS

The deployed test project is `spyclash-game-core` (`bbkfsgnordtdiblgdzkg`), Free/Nano in Ireland. Its exact ref and HTTPS origin are recorded in `client/staging-project.json` and the native compiled allowlist. This project contains synthetic test data only. The existing committed migration was applied as a transaction in the Dashboard SQL Editor; CLI migration history was not written. Do not push the local `config.toml` to cloud: its development-only Auth settings are not cloud settings.

Cloud runners require an owner-only (`0600`) ignored JSON configuration file mapping these environment names to strings:

- `SUPABASE_TEST_MODE`: `cloud-staging`
- `SUPABASE_TEST_PROJECT_REF`: `bbkfsgnordtdiblgdzkg`
- `SUPABASE_URL`: `https://bbkfsgnordtdiblgdzkg.supabase.co`
- `SUPABASE_ANON_KEY`: this project's publishable key

Provision the nine synthetic confirmed accounts with `scripts/provision-cloud-actors.mjs` only when needed; it additionally needs the test project's server key through `SUPABASE_SECRET_KEY`. Remove that server key after provisioning. The resulting `.local/cloud-actors.json` is owner-only and ignored. Test processes and native apps receive public client configuration plus synthetic credentials; they never receive the server key.

```sh
SUPABASE_TEST_CONFIG_FILE="$PWD/.local/cloud-env.json" node scripts/cloud-test.mjs
SUPABASE_TEST_CONFIG_FILE="$PWD/.local/cloud-env.json" node scripts/native-test.mjs \
  --cloud --simulators=SIMULATOR_A_UUID,SIMULATOR_B_UUID,SIMULATOR_C_UUID
```

The native runner requires the standalone lab app to be built and installed on three booted Simulators first. See [ios/README.md](ios/README.md) for build and manual launch instructions. It operates real native Auth/HTTP/WebSocket clients, takes state checkpoints, closes a real socket, refuses a connection, and drops a successful response after the database has committed. Run `scripts/audit-cloud.sql` with an administrative read-only session against this exact test project to verify database privileges and persisted invariants after testing.

## Command protocol

Authenticated clients call `game_command(p_request_id, p_room_id, p_action, p_payload)` through PostgREST RPC. A client generates a UUID for each new intent and keeps it unchanged until that intent has a definite result. Transport failure leaves the intent pending; a business rejection does not trigger an automatic new command.

Each accepted command executes in one database transaction:

1. Authenticate the actor and serialize duplicate request IDs.
2. Check the durable receipt; return its original result for an identical replay, or reject ID reuse with a different command.
3. Lock only the affected room, check membership/host privileges and the relevant match/revision fence.
4. Apply the command, increment the room revision, write the secret-free signal and store the request result atomically.

Database locks end with the transaction. There is no persisted account-wide writer lease. Commands to independent rooms do not share a game lock. No external HTTP calls, AI requests or push delivery run while the transaction holds the room lock.

The receipt confirms what happened to that command. It is **not the latest room snapshot**: after a replay, read `game_snapshot(p_room_id)` to get current state. A reply lost after commit can be recovered even after other players have changed the room.

Fences are captured when creating an intent, not refreshed on retry: readiness carries `membership_id` and `settings_revision`; leave carries `membership_id`; start and lobby close carry `lobby_id`; active-match commands carry `match_id`; settings updates carry `expected_revision`. Rejoining rotates membership identity; changed settings invalidate old readiness; returning to the lobby rotates lobby identity. The test client may fill omitted fences from its cached snapshot, but explicit caller values and queued requests remain unchanged.

## State and privacy

Phases are `lobby → playing → voting → finished`, plus `closed` and a return to the lobby. Lobby settings currently support `max_players` (3–12; default 6). The server chooses the spy and a word from a built-in test word list. This experiment has explicit simplified one-round voting and departure rules; it is not a claim of parity with the released game.

Authoritative tables and receipts live in `game_private`, outside the exposed Data API schemas. Public RPC wrappers run as the caller; narrow private privileged functions validate `auth.uid()` and ownership before access. RLS is enabled on all game tables. Direct client writes are not granted.

The public `game_room_signals` table exposes only synchronization metadata to current room members through RLS. Realtime is an invalidation hint: clients reread the authorized snapshot. A disconnected client subscribes again and rereads the snapshot to cover events missed while offline. Public signals never contain a word or role; each authorized snapshot reveals only that actor's private role/word.

The pinned Realtime SDK supports `postgres_changes_options: { wait: true, timeout: 15000 }`. The client uses it because the default `SUBSCRIBED` callback can precede an active PostgreSQL change stream on cold startup. After each acknowledged subscription it refreshes the snapshot, and while watching a room it reconciles at most once every three seconds with only one read in flight. Closing a watch clears its timer. WAL-delivery tests require real events separately from this fallback.

## Verification

`npm test` creates separate real Auth sessions and runs concurrent REST requests plus real Realtime subscriptions. The fault proxy can forward a command, receive its successful upstream response, then close the client socket before delivering that response. It can also stop listening entirely to create a real connection failure.

See [CLOUD-IOS-VERIFICATION.md](CLOUD-IOS-VERIFICATION.md) for the cloud and native build 168 results, and [VERIFICATION.md](VERIFICATION.md) for the original local baseline. These runs establish the tested concurrency and recovery behavior, not physical-device acceptance, full production game parity, regional availability or production load capacity.

Relevant platform contracts: [local Supabase](https://supabase.com/docs/guides/local-development/cli/getting-started), [database functions](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [Realtime database changes](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes).
