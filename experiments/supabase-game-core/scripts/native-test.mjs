import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cloudTestConfig, localConfig, eventually } from '../client/game-client.mjs';
import { faultProxy } from '../tests/fault-proxy.mjs';
import { loadTestFixture, testEnvironment } from './test-fixtures.mjs';
import { startNativeControl } from './native-control.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = testEnvironment();
const cloud = process.argv.includes('--cloud');
const mode = cloud ? 'cloud' : 'local';
let config;
if (cloud) config = cloudTestConfig(env);
else {
  const cliEnv = { ...env, DOCKER_HOST: env.DOCKER_HOST || `unix://${homedir()}/.colima/spyclash-supabase/docker.sock` };
  const response = spawnSync(resolve(root, 'node_modules/.bin/supabase'), ['status', '-o', 'json'], { cwd: root, env: cliEnv, encoding: 'utf8' });
  if (response.status !== 0) throw new Error('Local Supabase CLI status unavailable');
  const info = JSON.parse(response.stdout);
  config = localConfig({ SUPABASE_URL: info.API_URL, SUPABASE_ANON_KEY: info.ANON_KEY, DATABASE_URL: info.DB_URL });
}
const fixturePath = env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, `.local/${cloud ? 'cloud-' : ''}actors.json`);
const fixture = loadTestFixture(config, fixturePath);
const actorIDs = ['ios1', 'ios2', 'ios3'];
const actors = Object.fromEntries(actorIDs.map((id) => [id, fixture.actors.find((actor) => actor.id === id)]));
assert.ok(Object.values(actors).every(Boolean), 'Fixture needs ios1, ios2 and ios3');
const simulatorArg = process.argv.find((value) => value.startsWith('--simulators='));
const simulators = (simulatorArg?.split('=')[1] ?? env.SUPABASE_TEST_SIMULATORS ?? '').split(',');
if (simulators.length !== 3 || simulators.some((id) => !/^[A-Fa-f0-9-]{36}$/.test(id))) throw new Error('Provide exactly three Simulator UUIDs via --simulators=ID,ID,ID');
const pauseAt = new Set((process.argv.find((value) => value.startsWith('--pause-at='))?.split('=')[1] ?? '').split(',').filter(Boolean));
const output = resolve(root, `.local/native-${mode}`);
mkdirSync(output, { recursive: true, mode: 0o700 });
const proxy = await faultProxy(config.url, cloud ? { config } : undefined);
const control = await startNativeControl({ config, actors, transportURLs: { ios2: proxy.url } });
const roomID = randomUUID();
const checkpoints = [];
const receipts = [];

async function perform(clientID, command, { allowError = false } = {}) {
  const controlID = control.enqueue(clientID, command);
  const event = await control.waitResult(controlID, 90_000);
  if (!allowError) assert.equal(event.ok, true, `${clientID} ${command.op}/${command.action ?? ''}: ${event.error?.code ?? event.error?.message ?? 'native operation failed'}`);
  if (command.op === 'command' || command.op === 'retry') receipts.push({ client_id: clientID, request_id: command.request_id, ok: event.ok, result: event.result, error: event.error });
  return event;
}
function stateOf(event) { return event.state ?? event.result; }
function snapshotOf(event) { return event.result?.room_id && event.result?.players ? event.result : stateOf(event)?.snapshot; }
async function states() { return Object.fromEntries(await Promise.all(actorIDs.map(async (id) => [id, stateOf(await perform(id, { op: 'state' }))]))); }
async function visibleAt(revision, phase) {
  let visible;
  await eventually(async () => {
    visible = await states();
    return Object.values(visible).every((state) => state.snapshot?.revision >= revision && (!phase || state.snapshot?.phase === phase));
  }, { timeout: 25_000, message: 'Native visible snapshots did not converge' });
  return visible;
}
async function checkpoint(name, visible, extra = {}) {
  const evidence = { checkpoint: name, mode, backendURL: config.url, projectRef: config.projectRef ?? null, room_id: roomID, captured_at: new Date().toISOString(), native_states: visible, ...extra };
  const path = resolve(output, `${String(checkpoints.length + 1).padStart(2, '0')}-${name}.json`);
  writeFileSync(path, JSON.stringify(evidence, null, 2), { mode: 0o600 });
  checkpoints.push(path);
  console.log(`Native checkpoint ${name}: ${path}`);
  if (pauseAt.has(name)) {
    const resume = resolve(output, `resume-${name}`);
    if (existsSync(resume)) unlinkSync(resume);
    console.log(`Native UI held at ${name}; create ${resume} to continue.`);
    await eventually(() => existsSync(resume), { timeout: 600_000, message: 'Native checkpoint pause expired' });
    unlinkSync(resume);
  }
}
try {
  for (const [index, id] of actorIDs.entries()) {
    const launchEnv = { ...process.env, SIMCTL_CHILD_LAB_CLIENT_ID: id, SIMCTL_CHILD_LAB_CONTROL_URL: control.url, SIMCTL_CHILD_LAB_CONTROL_TOKEN: control.token };
    for (const key of ['SUPABASE_SECRET_KEY', 'SUPABASE_TEST_CONFIG_FILE', 'SUPABASE_TEST_ACTORS', 'SUPABASE_ANON_KEY', 'DATABASE_URL']) delete launchEnv[key];
    // The apps must already be built and installed by the iOS build workflow.
    // Credentials travel only via the authenticated loopback fixture endpoint.
    const result = spawnSync('xcrun', ['simctl', 'launch', '--terminate-running-process', simulators[index], 'com.spyclash.gamecore.lab'], { env: launchEnv, encoding: 'utf8' });
    if (result.status !== 0) throw new Error(`Could not launch native actor ${id}; verify installation and booted Simulator`);
  }
  const initial = await states();
  assert.equal(new Set(Object.values(initial).map((state) => state.user_id)).size, 3, 'Native actors must have distinct real Auth users');
  await perform('ios1', { op: 'command', room_id: roomID, action: 'create_room', payload: { name: actors.ios1.name, settings: { max_players: 6 } }, request_id: randomUUID() });
  await Promise.all(['ios2', 'ios3'].map((id) => perform(id, { op: 'command', room_id: roomID, action: 'join_room', payload: { name: actors[id].name }, request_id: randomUUID() })));
  // An old receipt is an acknowledgement, never an instruction to clear the
  // native UI for a new membership that was established after that receipt.
  const historicalLeaveID = randomUUID();
  await perform('ios2', { op: 'command', room_id: roomID, action: 'leave_room', payload: {}, request_id: historicalLeaveID });
  const rejoin = await perform('ios2', { op: 'command', room_id: roomID, action: 'join_room', payload: { name: actors.ios2.name }, request_id: randomUUID() });
  const newMembership = stateOf(rejoin).snapshot.own_membership_id;
  const historicalReplay = await perform('ios2', { op: 'command', room_id: roomID, action: 'leave_room', payload: {}, request_id: historicalLeaveID });
  assert.equal(stateOf(historicalReplay).room_id, roomID, 'Historical leave receipt must not evict the current native screen');
  assert.equal(stateOf(historicalReplay).snapshot.own_membership_id, newMembership);
  assert.equal(stateOf(historicalReplay).snapshot.revision, stateOf(rejoin).snapshot.revision);
  const lobby = Object.fromEntries(await Promise.all(actorIDs.map(async (id) => [id, snapshotOf(await perform(id, { op: 'snapshot', room_id: roomID }))])));
  await Promise.all(actorIDs.map((id) => perform(id, { op: 'command', room_id: roomID, action: 'set_ready', payload: { ready: true, membership_id: lobby[id].own_membership_id, settings_revision: lobby[id].settings_revision }, request_id: randomUUID() })));
  const start = await perform('ios1', { op: 'command', room_id: roomID, action: 'start_game', payload: { lobby_id: lobby.ios1.lobby_id }, request_id: randomUUID() });
  const playing = await visibleAt(start.result.revision, 'playing');
  assert.equal(Object.values(playing).filter((state) => state.snapshot.own_role === 'spy').length, 1);
  const matchID = playing.ios1.snapshot.match_id;
  await checkpoint('all-playing', playing, { command_receipt: start.result });

  const spyActor = actorIDs.find((id) => playing[id].snapshot.own_role === 'spy');
  const civilianActor = actorIDs.find((id) => id !== spyActor);
  const targetFor = (id) => playing[id === spyActor ? civilianActor : spyActor].user_id;
  await perform('ios2', { op: 'disconnect_realtime' });
  const forwardedBeforeOffline = proxy.stats.forwardedCommands;
  await proxy.disconnect();
  await perform('ios1', { op: 'command', room_id: roomID, action: 'open_voting', payload: { match_id: matchID }, request_id: randomUUID() });
  const cVote = await perform('ios3', { op: 'command', room_id: roomID, action: 'vote', payload: { match_id: matchID, target_id: targetFor('ios3') }, request_id: randomUUID() });
  const pendingID = randomUUID();
  const offline = await perform('ios2', { op: 'command', room_id: roomID, action: 'vote', payload: { match_id: matchID, target_id: targetFor('ios2') }, request_id: pendingID }, { allowError: true });
  assert.equal(offline.ok, false);
  assert.equal(offline.error?.ambiguous, true, 'Offline native command must report a real transport failure');
  assert.ok(stateOf(offline).pending_ids.includes(pendingID));
  assert.equal(proxy.stats.forwardedCommands, forwardedBeforeOffline, 'Offline command must never reach upstream');
  const disconnected = await states();
  assert.ok(disconnected.ios2.snapshot.revision < cVote.result.revision);
  await checkpoint('b-offline', disconnected, { last_server_receipt: cVote.result, native_transport_error: offline.error });

  await proxy.reconnect();
  await perform('ios2', { op: 'reconnect_realtime', room_id: roomID });
  const recovered = await visibleAt(cVote.result.revision, 'voting');
  assert.ok(recovered.ios2.pending_ids.includes(pendingID));
  await checkpoint('b-recovered', recovered, { last_server_receipt: cVote.result });

  proxy.dropNextResponse(pendingID);
  const lostACK = await perform('ios2', { op: 'retry', request_id: pendingID }, { allowError: true });
  assert.equal(lostACK.ok, false);
  assert.equal(lostACK.error?.ambiguous, true);
  assert.equal(proxy.stats.droppedResponses, 1);
  const finalVote = await perform('ios1', { op: 'command', room_id: roomID, action: 'vote', payload: { match_id: matchID, target_id: targetFor('ios1') }, request_id: randomUUID() });
  const replay = await perform('ios2', { op: 'retry', request_id: pendingID });
  assert.equal(replay.result.request_id, pendingID);
  assert.ok(replay.result.revision < finalVote.result.revision, 'Retry must recover the historical receipt after another native writer');
  const finished = await visibleAt(finalVote.result.revision, 'finished');
  for (const state of Object.values(finished)) {
    assert.equal(state.snapshot.winner, 'civilians');
    assert.equal(state.snapshot.votes.length, 3);
    assert.equal(state.pending_ids.length, 0);
  }
  await eventually(async () => {
    const latest = await states();
    return actorIDs.every((id) => latest[id].signals.includes(finalVote.result.revision));
  }, { timeout: 20_000, message: 'Native real sockets did not all record final WAL revision' });
  await checkpoint('finished', await states(), { command_receipt: finalVote.result, recovered_historical_receipt: replay.result, proxy: proxy.stats });
  writeFileSync(resolve(output, 'results.json'), JSON.stringify({ mode, backendURL: config.url, passed: true, room_id: roomID, checkpoints, command_receipts: receipts, native_events: Object.fromEntries(actorIDs.map((id) => [id, control.events(id)])) }, null, 2), { mode: 0o600 });
  console.log(`Native ${mode} acceptance passed: three independent apps, real Auth/RPC/WAL, offline retry and lost acknowledgement.`);
} catch (error) {
  writeFileSync(resolve(output, 'results.json'), JSON.stringify({ mode, backendURL: config.url, passed: false, error: error.message, room_id: roomID, checkpoints, command_receipts: receipts, native_events: Object.fromEntries(actorIDs.map((id) => [id, control.events(id)])) }, null, 2), { mode: 0o600 });
  throw error;
} finally {
  await control.close();
  await proxy.close();
}
