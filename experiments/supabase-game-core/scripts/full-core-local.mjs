import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, existsSync, readdirSync, mkdirSync, openSync, closeSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const local = resolve(root, '.local');
mkdirSync(local, { recursive: true, mode: 0o700 });
if (existsSync(resolve(root, 'supabase/.temp/project-ref'))) throw new Error('Refusing a cloud-linked local checkout.');
const env = { ...process.env, DOCKER_HOST: process.env.DOCKER_HOST || `unix://${homedir()}/.colima/spyclash-supabase/docker.sock` };
const status = spawnSync(resolve(root, 'node_modules/.bin/supabase'), ['status', '-o', 'json'], { cwd: root, env, encoding: 'utf8' });
if (status.status !== 0) throw new Error('Start the existing isolated local Supabase stack first.');
const info = JSON.parse(status.stdout);
for (const [key, port] of [['API_URL', '56321'], ['DB_URL', '56322']]) {
  const url = new URL(info[key]);
  if (url.hostname !== '127.0.0.1' || url.port !== port) throw new Error('Unexpected local test endpoint.');
}
const db = new pg.Client({ connectionString: info.DB_URL });
await db.connect();
try {
  await db.query('BEGIN');
  await db.query(readFileSync(resolve(root, 'supabase/schemas/full_game_core.sql'), 'utf8'));
  await db.query("NOTIFY pgrst, 'reload schema'");
  await db.query('COMMIT');
} catch (error) { await db.query('ROLLBACK'); throw error; }
finally { await db.end(); }
console.log('Applied full game schema to isolated local PostgreSQL.');
if (process.argv[2] === 'apply') process.exit(0);

const runEnv = { ...env, SUPABASE_URL: info.API_URL, SUPABASE_ANON_KEY: info.ANON_KEY, DATABASE_URL: info.DB_URL, FULL_CORE_URL: 'http://127.0.0.1:56325' };
const log = openSync(resolve(local, 'full-core-server.log'), 'w', 0o600);
const server = spawn(resolve(root, 'node_modules/.bin/deno'), ['run', '--allow-net=127.0.0.1:56321,127.0.0.1:56322,127.0.0.1:56325', '--allow-env', '--allow-read', 'scripts/full-core-serve.ts'], { cwd: root, env: runEnv, stdio: ['ignore', log, log] });
closeSync(log);
try {
  let ready = false;
  for (let attempt = 0; attempt < 80; attempt++) {
    if (server.exitCode !== null) throw new Error('Local full-core server stopped. See .local/full-core-server.log.');
    try { const response = await fetch(runEnv.FULL_CORE_URL); ready = response.status === 405; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!ready) throw new Error('Local full-core server failed to become ready.');
  const directory = resolve(root, 'tests/full-core');
  const files = readdirSync(directory).filter(n => n.endsWith('.test.mjs')).map(n => `tests/full-core/${n}`);
  if (!files.length) throw new Error('No full-core integration tests.');
  const test = spawn(process.execPath, ['--experimental-strip-types', '--test', '--test-concurrency=1', ...files], { cwd: root, env: runEnv, stdio: 'inherit' });
  process.exitCode = await new Promise(resolve => test.once('exit', code => resolve(code ?? 1)));
} finally {
  if (server.exitCode === null && server.signalCode === null) {
    const stopped = new Promise(resolve => server.once('exit', resolve));
    server.kill('SIGTERM');
    await stopped;
  }
}
