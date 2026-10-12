import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cloudTestConfig, syntheticTestActors } from '../client/game-client.mjs';
import { loadTestFixture, testEnvironment } from './test-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = testEnvironment();
const config = cloudTestConfig(env);
if (!env.SUPABASE_TEST_ACTORS) {
  const fixture = loadTestFixture(config, env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, '.local/cloud-actors.json'));
  env.SUPABASE_TEST_ACTORS = JSON.stringify(fixture.actors.filter((actor) => actor.id.startsWith('js')));
}
const actors = syntheticTestActors(env);
if (process.argv.includes('--check')) {
  console.log(JSON.stringify({ mode: config.mode, projectRef: config.projectRef, syntheticActors: actors.length, credentials: 'memory-only', valid: true }));
} else {
  mkdirSync(resolve(root, '.local'), { recursive: true, mode: 0o700 });
  // The test process gets only public client configuration and synthetic actor
  // credentials, even if the parent's provisioning config also held an admin key.
  const testEnv = { ...env };
  delete testEnv.SUPABASE_SECRET_KEY;
  delete testEnv.SUPABASE_TEST_CONFIG_FILE;
  const result = spawnSync(process.execPath, [
    '--test', '--test-concurrency=1', '--test-reporter=spec', '--test-reporter=junit',
    '--test-reporter-destination=stdout', '--test-reporter-destination=.local/cloud-test-results.xml',
    'tests/cloud/game-core.test.mjs',
  ], { cwd: root, env: testEnv, stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
}
