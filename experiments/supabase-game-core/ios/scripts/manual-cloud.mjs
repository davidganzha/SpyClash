import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cloudTestConfig, eventually } from '../../client/game-client.mjs';
import { loadTestFixture, testEnvironment } from '../../scripts/test-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const env = testEnvironment();
const config = cloudTestConfig(env);
const fixture = loadTestFixture(config, env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, '.local/cloud-actors.json'));
const ids = (process.argv.find((arg) => arg.startsWith('--simulators='))?.split('=')[1] ?? '').split(',');
assert.ok(ids.length === 3 && new Set(ids).size === 3 && ids.every((id) => /^[a-f0-9-]{36}$/i.test(id)), 'Provide three distinct Simulator UUIDs');
const active = spawnSync('pgrep', ['-f', '(^|/)native-test[.]mjs'], { encoding: 'utf8' });
assert.equal(active.status, 1, 'Stop the automated native runner before manual launch');
const bundle = 'com.spyclash.gamecore.lab';
const plans = ids.map((simulator, index) => {
  const actor = fixture.actors.find((entry) => entry.id === `ios${index + 1}`);
  assert.ok(actor, 'Fixture must contain ios1, ios2 and ios3');
  const response = spawnSync('xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data'], { encoding: 'utf8' });
  assert.equal(response.status, 0, 'Boot all three Simulators and install the lab app first');
  const container = response.stdout.trim();
  assert.ok(container.startsWith('/'), 'Unexpected Simulator data container');
  return { simulator, actor, container, path: resolve(container, 'Documents/LabRuntime/cloud.json') };
});
if (process.argv.includes('--check')) {
  console.log(JSON.stringify({ projectRef: config.projectRef, simulators: plans.length, valid: true, mode: 'direct-cloud' }));
} else {
  const users = new Set();
  const processes = [];
  for (const plan of plans) {
    mkdirSync(dirname(plan.path), { recursive: true, mode: 0o700 });
    writeFileSync(plan.path, JSON.stringify({ backendURL: config.url, publishableKey: config.anonKey,
      email: plan.actor.email, password: plan.actor.password, name: plan.actor.name }), { mode: 0o600 });
    chmodSync(plan.path, 0o600);
    const launchEnv = { ...process.env };
    for (const key of Object.keys(launchEnv)) {
      if (key.startsWith('SIMCTL_CHILD_LAB_') || key.startsWith('LAB_') || key.startsWith('SUPABASE_') || key === 'DATABASE_URL') delete launchEnv[key];
    }
    launchEnv.SIMCTL_CHILD_LAB_CONFIG_PATH = plan.path;
    const started = Date.now();
    const launch = spawnSync('xcrun', ['simctl', 'launch', '--terminate-running-process', plan.simulator, bundle], { env: launchEnv, encoding: 'utf8' });
    assert.equal(launch.status, 0, 'Could not launch installed native lab app');
    const pid = Number(launch.stdout.trim().match(/: (\d+)$/)?.[1]);
    assert.ok(Number.isInteger(pid) && pid > 0, 'Launch did not return a process ID');
    const evidence = resolve(plan.container, 'Documents/Evidence/state.json');
    let state;
    await eventually(() => {
      try {
        if (statSync(evidence).mtimeMs < started) return false;
        state = JSON.parse(readFileSync(evidence, 'utf8'));
        return state.client_id === 'manual' && Boolean(state.user_id) && state.last_error === '';
      } catch { return false; }
    }, { timeout: 30_000, message: 'Direct cloud sign-in did not produce fresh successful native evidence' });
    process.kill(pid, 0);
    users.add(state.user_id);
    processes.push({ actor: plan.actor.id, simulator: plan.simulator, pid, authenticated: true });
  }
  assert.equal(users.size, 3, 'Manual clients must use independent Auth identities');
  console.log(JSON.stringify({ projectRef: config.projectRef, mode: 'direct-cloud', proxy: false, controller: false, independentActors: users.size, processes }));
}
