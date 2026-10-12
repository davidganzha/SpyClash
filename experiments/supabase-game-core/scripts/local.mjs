import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = resolve(root, 'node_modules/.bin/supabase');
const env = { ...process.env };
const network = 'spyclash-game-core-loopback';
const socket = resolve(homedir(), '.colima/spyclash-supabase/docker.sock');
if (!env.DOCKER_HOST && existsSync(socket)) env.DOCKER_HOST = `unix://${socket}`;
const dockerEndpoint = env.DOCKER_HOST ?? (() => {
  const result = spawnSync('docker', ['context', 'inspect', '--format', '{{json .Endpoints.docker.Host}}'], { env, encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error('A local Docker runtime is required. Start the dedicated Colima profile first.');
  return JSON.parse(result.stdout);
})();
const dockerURL = new URL(dockerEndpoint);
if (dockerURL.protocol !== 'unix:' &&
    !(dockerURL.protocol === 'tcp:' && ['127.0.0.1', 'localhost', '[::1]'].includes(dockerURL.hostname))) {
  throw new Error('This local test runner refuses a remote Docker endpoint.');
}
const localDir = resolve(root, '.local');
mkdirSync(localDir, { recursive: true, mode: 0o700 });
if (existsSync(resolve(root, 'supabase/.temp/project-ref'))) {
  throw new Error('This test runner refuses a cloud-linked Supabase directory. Use an unlinked local checkout.');
}
if (!readFileSync(resolve(root, 'supabase/config.toml'), 'utf8').includes('project_id = "spyclash-game-core-test"')) {
  throw new Error('Unexpected project ID: refusing to operate on another stack.');
}

function run(args, extra = {}) {
  const result = spawnSync(cli, [...args, '--network-id', network], { cwd: root, env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, ...extra });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`Local Supabase command failed: ${args.join(' ')}. ${result.stderr || 'See .local/start.log.'}`);
  return result.stdout;
}
function status() {
  const value = JSON.parse(run(['status', '-o', 'json']));
  for (const [key, port] of [['API_URL', '56321'], ['DB_URL', '56322']]) {
    const url = new URL(value[key]);
    if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.port !== port) {
      throw new Error(`Refusing unexpected ${key}; this runner only targets the isolated local stack.`);
    }
  }
  return value;
}
function ensureLoopbackNetwork() {
  let result = spawnSync('docker', ['network', 'inspect', network], { env, encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    result = spawnSync('docker', ['network', 'create', '--driver', 'bridge', '--opt', 'com.docker.network.bridge.host_binding_ipv4=127.0.0.1', network], { env, encoding: 'utf8' });
    if (result.status !== 0) throw new Error(`Cannot create isolated loopback network: ${result.stderr}`);
    result = spawnSync('docker', ['network', 'inspect', network], { env, encoding: 'utf8' });
  }
  const [details] = JSON.parse(result.stdout);
  if (details.Options?.['com.docker.network.bridge.host_binding_ipv4'] !== '127.0.0.1') {
    throw new Error('Refusing a test network that publishes ports beyond loopback.');
  }
}
function show(value) {
  console.log(JSON.stringify({ project: 'spyclash-game-core-test', api: value.API_URL, studio: value.STUDIO_URL, database: '127.0.0.1:56322', runtime: env.DOCKER_HOST ? 'configured local Docker socket' : 'Docker default context' }, null, 2));
}

const action = process.argv[2];
if (action === 'start') {
  console.log('Starting isolated local Supabase; first launch downloads container images.');
  ensureLoopbackNetwork();
  const fd = openSync(resolve(localDir, 'start.log'), 'w', 0o600);
  try { run(['start', '--exclude', 'storage-api,imgproxy,edge-runtime,logflare,vector,supavisor'], { stdio: ['ignore', fd, fd] }); }
  finally { closeSync(fd); }
  show(status());
} else if (action === 'stop') {
  run(['stop'], { stdio: 'inherit' });
} else if (action === 'status') {
  show(status());
} else if (action === 'verify') {
  const info = status();
  const lint = run(['db', 'lint', '--local', '--schema', 'public,game_private', '--fail-on', 'warning']);
  const advisors = run(['db', 'advisors', '--local', '--type', 'all', '--level', 'info', '--fail-on', 'warn', '-o', 'json']);
  writeFileSync(resolve(localDir, 'lint.json'), lint, { mode: 0o600 });
  writeFileSync(resolve(localDir, 'advisors.json'), advisors, { mode: 0o600 });
  console.log('Database lint passed; advisors found no warnings or errors. Info-level findings:');
  const counts = {};
  for (const item of JSON.parse(advisors)) counts[item.name] = (counts[item.name] ?? 0) + 1;
  console.log(JSON.stringify(counts, null, 2));
  const audit = spawnSync(process.execPath, ['scripts/audit-database.mjs'], {
    cwd: root, env: { ...env, DATABASE_URL: info.DB_URL }, encoding: 'utf8',
  });
  if (audit.error) throw audit.error;
  if (audit.status !== 0) throw new Error(`Database acceptance audit failed: ${audit.stderr}`);
  writeFileSync(resolve(localDir, 'audit.json'), audit.stdout, { mode: 0o600 });
  console.log(audit.stdout.trim());
} else if (action === 'apply') {
  const info = status();
  const db = new pg.Client({ connectionString: info.DB_URL });
  await db.connect();
  try {
    await db.query('BEGIN');
    await db.query(readFileSync(resolve(root, 'supabase/schemas/game_core.sql'), 'utf8'));
    await db.query("NOTIFY pgrst, 'reload schema'");
    await db.query('COMMIT');
    console.log('Game core schema applied atomically to local PostgreSQL.');
  } catch (error) { await db.query('ROLLBACK'); throw error; }
  finally { await db.end(); }
} else if (action === 'test') {
  const info = status();
  const testFiles = readdirSync(resolve(root, 'tests')).filter(name => name.endsWith('.test.mjs')).map(name => `tests/${name}`);
  if (!testFiles.length) throw new Error('No integration test files found.');
  const result = spawnSync(process.execPath, [
    '--test', '--test-concurrency=1', '--test-reporter=spec', '--test-reporter=junit',
    '--test-reporter-destination=stdout', '--test-reporter-destination=.local/test-results.xml', ...testFiles,
  ], { cwd: root, env: { ...env, SUPABASE_URL: info.API_URL, SUPABASE_ANON_KEY: info.ANON_KEY, DATABASE_URL: info.DB_URL }, stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} else {
  throw new Error('Usage: node scripts/local.mjs start|stop|status|verify|apply|test');
}
