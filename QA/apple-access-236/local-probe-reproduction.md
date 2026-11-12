# Local membership concurrency evidence

The deployed-v25 handler did **not** reproduce the live 150-second membership hang in this local setup. Direct Postgres, Supavisor transaction mode and Supavisor session mode all passed under both ordinary Deno and official Edge Runtime 1.77.9. These results establish local compatibility; they do not prove that the proposed production change resolves the device incident.

Each mode used a fresh process/Edge container. Each 3/12/30-request scenario creates a fresh postgres.js client, handler, account and auth session. Its first simultaneous wave starts with the exact 41-byte membership/check command, then profile/current and notifications/summary, without priming the connection or profile. Profiles initially lack a spy_id, so real first-use allocation runs. The 3-request scenario repeats after 16 seconds, beyond idle_timeout=15. Every wave has a 20-second deadline. Authentication is injected for synthetic local users; the handler's real session/account checks and database transactions run. Empty entitlements must cause zero provider calls.

Each completed suite has 93 cold/repeated/idle requests, 24 concurrent requests across two distinct accounts, and a transaction rollback assertion. Identity checks compare each profile's ID and unique display name and distinguish free membership from an active local grant. A thrown transaction must not persist its marker. Test fixtures are removed in finally blocks. No Apple purchase is created.

The baseline `local-*-concurrency.json` and `edge-*-concurrency.json` files use postgres.js 3.4.9, prepare=false, max=3, idle_timeout=15 and connect_timeout=8. The exact downloaded v25 source is recorded in `baseline-probe-source-manifest.json` (77 files). It remains at `.local/repair235/candidate`; it is not interchangeable with the current repository source, which contains unrelated pre-existing changes.

The eight recorded suites contain **936 verified handler responses and eight successful rollback assertions**. `local-concurrency-comparison.json` summarizes every run. The final simultaneous max=1 workers reached a maximum request duration of 2.925/2.930 seconds at 30 concurrent requests, below the 20-second deadline.

The final `final-session-max1-worker-*.json` files run the 78-file candidate in `.local/repair236/candidate`, including its request-stage diagnostic, in **two simultaneous fresh Edge workers with max=1 each**, sharing a three-session local pool. Each worker performs the full suite above. `candidate-manifest.json` records the candidate source. The local handler harness injects the same connection options as the candidate index; it does not test deployment, real Supabase Auth, TLS or hosted infrastructure.

The temporary pooler is `supabase/supavisor:2.9.13` (digest `sha256:07f1a6098ffc04b80263bca4eb5c3e7bd2e03dfd1fc465aa108d7329000a1a4e`), with an isolated metadata database and pool_size=3. The Edge image is `public.ecr.aws/supabase/edge-runtime:v1.77.9` (digest `sha256:6b850a2ccf0bf50ecac9accff8098095cd191c389c2a53c59b857aa0f53a8343`). It reports compatibility with Deno 2.1.4. Host runs use Deno 2.8.3. Local pooler/database traffic is unencrypted on an isolated Docker bridge; this differs from hosted production.

A separate accidental run started two max=3 session workers concurrently. The three-session local pool immediately rejected excess connections with EMAXCONNSESSION/XX000. `session-capacity-observation.json` records this capacity failure; it is distinct from the live hang. Session runs must budget connections across workers. The final max=1 pair exercises two simultaneous workers within the same three-session cap.

## Reproduce on the existing local test stack

Run from the repository root. The database must already contain the project's test migrations. Obtain its local Postgres URL from `supabase status -o json` in the test-stack directory and put it in `SPYCLASH_TEST_DATABASE_URL`. It must point to `127.0.0.1:56322/postgres`; the script rejects other host databases. Do not use hosted credentials.

```sh
export DOCKER_HOST=unix:///Users/davidganzha/.colima/spyclash-supabase/docker.sock
export SPYCLASH_TEST_DATABASE_URL='postgresql://postgres:LOCAL_PASSWORD@127.0.0.1:56322/postgres'
deno run --no-lock --node-modules-dir=none --allow-env --allow-net=127.0.0.1 --allow-write=.local/apple-access-236 QA/apple-access-236/local-pooler-setup.ts
docker run --rm -d --name spyclash-repair235-pooler-probe --network spyclash-game-core-loopback -p 127.0.0.1:59015:5432 -p 127.0.0.1:59016:6543 --env-file .local/apple-access-236/pooler.env -v "$PWD/QA/apple-access-236/local-pooler.exs:/etc/pooler/pooler.exs:ro" supabase/supavisor:2.9.13 /bin/sh -c '/app/bin/migrate && /app/bin/supavisor eval "$(cat /etc/pooler/pooler.exs)" && /app/bin/server'
```

For baseline host runs, set the exact snapshot handler. Omit the override to exercise the current repository handler instead. Run modes serially so another max=3 session client cannot consume this small fixture pool.

```sh
export SPYCLASH_TEST_HANDLER_URL="file://$PWD/.local/repair235/candidate/app-services/handler.ts"
export SPYCLASH_TEST_POOL_MAX=3
deno run --no-lock --node-modules-dir=none --allow-env --allow-read --allow-net=127.0.0.1 QA/apple-access-236/membership-concurrency.ts direct
deno run --no-lock --node-modules-dir=none --allow-env --allow-read --allow-net=127.0.0.1 QA/apple-access-236/membership-concurrency.ts transaction
deno run --no-lock --node-modules-dir=none --allow-env --allow-read --allow-net=127.0.0.1 QA/apple-access-236/membership-concurrency.ts session
```

For Edge, `edge-runtime/index.ts` statically imports the repository handler. Replaying an archived candidate requires a static import of that candidate because Edge resolves its dependency graph before serving requests. This generates a local wrapper and private environment file for the final candidate:

```sh
python3 - <<'PY'
import hashlib, os, pathlib, subprocess, urllib.parse
root = pathlib.Path.cwd()
source = '.local/repair236/candidate/app-services/handler.ts'
out = root / '.local/apple-access-236/edge'
out.mkdir(parents=True, exist_ok=True)
template = (root / 'QA/apple-access-236/edge-runtime/index.ts').read_text()
template = template.replace("'../membership-concurrency.ts'", "'../../../QA/apple-access-236/membership-concurrency.ts'")
template = template.replace("'../../../experiments/supabase-game-core/supabase/functions/app-services/handler.ts'", repr(os.path.relpath(root / source, out)))
(out / 'index.ts').write_text(template)
def ip(name):
    return subprocess.check_output(['docker', 'inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', name], text=True).strip()
url = urllib.parse.urlsplit(os.environ['SPYCLASH_TEST_DATABASE_URL'])
url = urllib.parse.urlunsplit(url._replace(netloc=url.netloc.replace('127.0.0.1:56322', 'supabase_db_spyclash-game-core-test:5432')))
values = {'SPYCLASH_TEST_DATABASE_URL': url, 'SPYCLASH_TEST_DATABASE_IP': ip('supabase_db_spyclash-game-core-test'), 'SPYCLASH_TEST_POOLER_IP': ip('spyclash-repair235-pooler-probe'), 'SPYCLASH_TEST_HANDLER_SHA256': hashlib.sha256((root / source).read_bytes()).hexdigest(), 'SPYCLASH_TEST_POOL_MAX': '1', 'SPYCLASH_TEST_MODE': 'session'}
env = out / 'worker.env'
env.write_text(''.join(key + '=' + value + '\n' for key, value in values.items()))
env.chmod(0o600)
PY
docker run --rm -d --name spyclash-probe-worker-a --network spyclash-game-core-loopback -p 127.0.0.1:59017:9000 --env-file .local/apple-access-236/edge/worker.env -v "$PWD:/repo:ro" public.ecr.aws/supabase/edge-runtime:v1.77.9 start --main-service /repo/.local/apple-access-236/edge
docker run --rm -d --name spyclash-probe-worker-b --network spyclash-game-core-loopback -p 127.0.0.1:59018:9000 --env-file .local/apple-access-236/edge/worker.env -v "$PWD:/repo:ro" public.ecr.aws/supabase/edge-runtime:v1.77.9 start --main-service /repo/.local/apple-access-236/edge
```

The bridge-IP overrides address Edge's inability to resolve the local Docker names in this environment. Overrides are restricted to the inspected local 172.18.0.x bridge. After both `/` readiness endpoints respond, request `/run` on both ports concurrently (each completes in about 20 seconds); save the JSON results. Never run another session client against this small pool during the comparison.

```sh
python3 - <<'PY'
import concurrent.futures, pathlib, urllib.request
def run(port):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/run', timeout=70) as response:
        pathlib.Path(f'.local/apple-access-236/worker-{port}.json').write_bytes(response.read())
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(run, [59017, 59018]))
PY
docker stop -t 1 spyclash-probe-worker-a spyclash-probe-worker-b spyclash-repair235-pooler-probe
deno run --no-lock --node-modules-dir=none --allow-env --allow-net=127.0.0.1 QA/apple-access-236/local-pooler-setup.ts cleanup
```

Remove the generated private environment files after cleanup. Do not stop or reconfigure the shared local Supabase stack. The completed investigation removed its task-owned worker/pooler containers and metadata database; image caches and non-secret result files remain.

Supabase documents the transaction-mode pipeline risk in its [Postgres.js guide](https://supabase.com/docs/guides/database/postgres-js). The local all-pass baseline neither disproves that warning nor identifies it as the confirmed cause of this incident.
