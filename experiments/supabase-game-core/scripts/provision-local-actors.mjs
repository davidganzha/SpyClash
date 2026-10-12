import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { localConfig } from '../client/game-client.mjs';
import { loadTestFixture } from './test-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = { ...process.env, DOCKER_HOST: process.env.DOCKER_HOST || `unix://${homedir()}/.colima/spyclash-supabase/docker.sock` };
const result = spawnSync(resolve(root, 'node_modules/.bin/supabase'), ['status', '-o', 'json'], { cwd: root, env, encoding: 'utf8' });
if (result.status !== 0) throw new Error('Local Supabase status is unavailable');
const info = JSON.parse(result.stdout);
const config = localConfig({ SUPABASE_URL: info.API_URL, SUPABASE_ANON_KEY: info.ANON_KEY, DATABASE_URL: info.DB_URL });
if (config.url !== 'http://127.0.0.1:56321') throw new Error('Provisioning is restricted to the isolated local game-core stack');
const path = resolve(root, '.local/actors.json');
if (existsSync(path) && !process.argv.includes('--fresh')) {
  const existing = loadTestFixture(config, path);
  console.log(JSON.stringify({ backend: config.url, actors: existing.actors.length, reused: true }));
} else {
  if (!info.SERVICE_ROLE_KEY) throw new Error('Local CLI did not expose its admin key');
  const runID = randomUUID();
  const actors = [];
  for (const id of ['ios1', 'ios2', 'ios3', 'js1', 'js2', 'js3', 'js4', 'js5', 'js6']) {
    const actor = { id, email: `game-core-${runID}-${id}@example.test`, password: `${randomUUID()}!Aa7`, name: id.toUpperCase() };
    const response = await fetch(`${config.url}/auth/v1/admin/users`, {
      method: 'POST', redirect: 'error',
      headers: { apikey: info.SERVICE_ROLE_KEY, Authorization: `Bearer ${info.SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: actor.email, password: actor.password, email_confirm: true }),
    });
    if (!response.ok) throw new Error(`Local synthetic actor provisioning failed (${response.status})`);
    actors.push(actor);
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, JSON.stringify({ backendURL: config.url, projectRef: null, actors }, null, 2), { mode: 0o600 });
  chmodSync(path, 0o600);
  console.log(JSON.stringify({ backend: config.url, actors: actors.length, created: true, credentials: 'owner-only ignored fixture' }));
}
