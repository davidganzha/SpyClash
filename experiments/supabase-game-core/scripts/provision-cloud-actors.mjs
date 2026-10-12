import { randomUUID } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cloudTestConfig } from '../client/game-client.mjs';
import { loadTestFixture, testEnvironment } from './test-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = testEnvironment();
const config = cloudTestConfig(env);
const secret = env.SUPABASE_SECRET_KEY;
let isAdminKey = /^sb_secret_[A-Za-z0-9_-]+$/.test(secret ?? '');
try { isAdminKey ||= secret.split('.').length === 3 && JSON.parse(Buffer.from(secret.split('.')[1], 'base64url').toString()).role === 'service_role'; } catch { /* reject below */ }
if (!isAdminKey) throw new Error('Provisioning needs the exact staging project secret or service-role key; management PATs are refused');
const path = env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, '.local/cloud-actors.json');
if (existsSync(path) && !process.argv.includes('--fresh')) {
  const fixture = loadTestFixture(config, path);
  console.log(JSON.stringify({ projectRef: config.projectRef, actors: fixture.actors.length, reused: true }));
} else {
  const runID = randomUUID();
  const actors = [];
  for (const id of ['ios1', 'ios2', 'ios3', 'js1', 'js2', 'js3', 'js4', 'js5', 'js6']) {
    const actor = { id, email: `game-core-${runID}-${id}@example.test`, password: `${randomUUID()}!Aa7`, name: id.toUpperCase() };
    const response = await fetch(`${config.url}/auth/v1/admin/users`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20_000),
      headers: { apikey: secret, Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: actor.email, password: actor.password, email_confirm: true }),
    });
    if (!response.ok) throw new Error(`Staging synthetic actor provisioning failed (${response.status}); no response body logged`);
    actors.push(actor);
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, JSON.stringify({ backendURL: config.url, projectRef: config.projectRef, actors }, null, 2), { mode: 0o600 });
  chmodSync(path, 0o600);
  console.log(JSON.stringify({ projectRef: config.projectRef, actors: actors.length, created: true, credentials: 'owner-only ignored fixture' }));
}
