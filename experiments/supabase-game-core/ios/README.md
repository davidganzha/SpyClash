# SpyClash Game Core Lab — native iOS experiment

Standalone SwiftUI application, **not the production SpyClash app migrated**.
Bundle: `com.spyclash.gamecore.lab`; scheme: `SpyClashGameCoreLab`; build: 168.
No Base44, purchases, production authentication, external Swift packages, or production assets.

```sh
cd experiments/supabase-game-core/ios
xcodegen generate
xcodebuild -project SpyClashGameCoreLab.xcodeproj -scheme SpyClashGameCoreLab \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Launch with either a local test controller (preferred for orchestrated native tests):

- `LAB_CLIENT_ID=ios1` (separate synthetic account per Simulator)
- `LAB_CONTROL_URL=http://127.0.0.1:<fixture-port>`
- `LAB_CONTROL_TOKEN=<random fixture token>`

or `LAB_CONFIG_PATH` pointing to a local JSON file with `backendURL`, `publishableKey`,
`email`, `password`, `name`, and optional `transportURL`. Direct launch environment
equivalents are `LAB_BACKEND_URL`, `LAB_PUBLISHABLE_KEY`, `LAB_EMAIL`, `LAB_PASSWORD`,
`LAB_NAME`, and optional `LAB_TRANSPORT_URL`. Do not commit runtime credentials.
Manual synthetic sign-in is also available in the app.

After the automated cloud test finishes, launch the installed apps for manual play
from the experiment directory:

```sh
SUPABASE_TEST_CONFIG_FILE="$PWD/.local/cloud-env.json" node ios/scripts/manual-cloud.mjs \
  --simulators=SIMULATOR_A_UUID,SIMULATOR_B_UUID,SIMULATOR_C_UUID
```

Add `--check` to validate without launching. The helper refuses an active native
test runner, writes owner-only synthetic configuration into each Simulator app's
data container, and verifies fresh independent native sign-ins and live processes.
It uses the canonical cloud origin directly, without a fault proxy or controller.
Create a room in client A, copy its room UUID into B and C, ready all players,
then start on A. Rerun the helper after terminating the apps; the launch environment
is not retained when launching from a home-screen icon.

The compiled `Configuration/BackendAllowlist.json` permits the isolated local
stack and the explicitly selected cloud test project `bbkfsgnordtdiblgdzkg`
(`spyclash-game-core`). Another cloud project requires its **exact project ref**
in `allowedProjectRefs` before rebuilding. No wildcard cloud hosts are accepted.
Keys must be publishable or legacy `anon`; privileged keys are rejected. Accounts
must use `example.test` or `example.invalid`. Optional fault proxy transports must
be loopback HTTP, while the canonical backend still passes the compiled allowlist.
Redirects are refused. Auth sessions and control credentials remain in memory.

Native URLSession calls perform real password Auth, commands and snapshots. Native
URLSessionWebSocketTask implements the documented Supabase/Phoenix JSON v1 protocol,
including heartbeats and `postgres_changes_options.wait=true` readiness. WSS always
connects directly to the canonical backend; a fixture can close the real native
socket independently. A three-second authoritative refresh reconciles missed hints.

Commands bind membership/settings/lobby/match generations once. Ambiguous transport
failures retain the exact pending request; retry never replaces it with a new UUID
or refreshes its intent. Pending commands survive app restart for the same synthetic
actor. Snapshots cannot move backwards by revision. Successful command receipts are
preserved even if the subsequent snapshot or WebSocket connection fails.

Controller contract (all requests have `Authorization: Bearer <control-token>`):

- `GET /clients/<id>/config`: runtime JSON configuration above.
- `GET /clients/<id>/next`: 204, or `{id,op,room_id?,action?,payload?,request_id?}`.
- Operations: `command`, `snapshot`, `watch`, `retry`, `disconnect_realtime`,
  `reconnect_realtime`, `state`. `watch`/reconnect wait for actual subscription
  readiness and then read a snapshot.
- `POST /clients/<id>/events`: `{event,client_id,sequence,control_id?,ok,result?,error?,state}`.
  Errors use `{code,message,ambiguous}`. No tokens/passwords/keys are reported.

Each app writes `Documents/Evidence/state.json` and `pending-commands.json` with
sanitized test state and pending command metadata. State includes only the actor's
authorized snapshot, its own role/word, revisions, receipt and signal history.
These synthetic evidence files are not production user data.
