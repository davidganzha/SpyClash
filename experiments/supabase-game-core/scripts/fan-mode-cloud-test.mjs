import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { cloudTestConfig, requireAllowedTestTarget } from '../client/game-client.mjs';
import { loadTestFixture, testEnvironment } from './test-fixtures.mjs';

// Requires the existing owner-only fixture/config files and explicit authorization
// to mutate this exact backend. --check validates local inputs without networking.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = testEnvironment({ SUPABASE_TEST_CONFIG_FILE: resolve(root, '.local/cloud-env.json'), ...process.env });
const config = cloudTestConfig(env);
const fixture = loadTestFixture(config, env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, '.local/cloud-actors.json'));
const credentials = ['js1', 'js2', 'js3', 'js4'].map(id => {
  const actor = fixture.actors.find(item => item.id === id);
  assert.ok(actor, `Missing synthetic fixture ${id}`);
  return actor;
});
const endpoint = `${config.url}/functions/v1/full-game-core`;
requireAllowedTestTarget(endpoint, config);
const reportPath = resolve(env.FAN_CLOUD_REPORT_FILE ?? resolve(root, '.local/fan-mode-cloud-results.json'));
if (process.argv.includes('--check')) {
  console.log(JSON.stringify({ valid: true, projectRef: config.projectRef, endpoint, syntheticActors: credentials.length, credentials: 'memory-only', mutations: false, reportPath }));
  process.exit(0);
}

const caps = ['multi_spy_v1', 'fan_mode_v1'];
const allTarget = '__fan_all_spies__', noneTarget = '__fan_no_spies__';
const clients = [], rooms = [];
const started = Date.now();
let stage = 'initializing';
const report = { projectRef: config.projectRef, endpoint, startedAt: new Date().toISOString(), tests: [], ownedRooms: [], cleanupErrors: [], credentialsPersisted: false };
const safeError = error => ({ kind: /^[\w-]+$/.test(error?.name || '') ? error.name : 'Error', code: /^[\w-]+$/.test(error?.code || '') ? error.code : 'check_failed', stage });
const check = (condition, label) => { stage = label; assert.ok(condition); };
function persist() {
  mkdirSync(dirname(reportPath), { recursive: true, mode: 0o700 });
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  chmodSync(reportPath, 0o600);
}
async function client(fixtureActor) {
  const sdk = createClient(config.url, config.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: (input, options) => {
      requireAllowedTestTarget(String(input), config);
      return fetch(input, { ...options, redirect: 'error', signal: options?.signal ?? AbortSignal.timeout(30_000) });
    } },
  });
  stage = 'synthetic_password_sign_in';
  const { data, error } = await sdk.auth.signInWithPassword({ email: fixtureActor.email, password: fixtureActor.password });
  if (error) throw error;
  check(data.session && data.user, 'auth_session_present');
  return {
    id: data.user.id, email: `${data.user.id.toLowerCase()}@example.test`, sdk,
    async send(body) {
      stage = `http_${body.action}`;
      requireAllowedTestTarget(endpoint, config);
      const response = await fetch(endpoint, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000), headers: {
        Authorization: `Bearer ${data.session.access_token}`, apikey: config.anonKey, 'Content-Type': 'application/json',
      }, body: JSON.stringify({ client_capabilities: caps, ...body }) });
      return { status: response.status, body: await response.json() };
    },
  };
}
async function ok(actor, body) {
  const result = await actor.send(body);
  if (result.status !== 200) { const error = new Error('Game command failed'); error.code = result.body.code || `http_${result.status}`; throw error; }
  return result.body;
}
async function read(actor, room) {
  return (await ok(actor, { action: 'get_room', room_id: typeof room === 'string' ? room : room.id })).room;
}
function bodyFor(room, action, values = {}, requestID = randomUUID()) {
  return { action, request_id: requestID, ...(room ? { room_id: room.id } : {}),
    ...(['arm_roulette', 'toggle_ready', 'begin_ready_check'].includes(action) ? { expected_lobby_revision: room.lobby_revision } : {}),
    ...(['close_room', 'toggle_ready'].includes(action) ? { expected_membership_id: room.viewer_membership_id } : {}),
    ...(room?.match_id ? { expected_match_id: room.match_id } : {}), ...values };
}
async function act(actor, room, action, values = {}) {
  return ok(actor, bodyFor(await read(actor, room), action, values));
}
async function close(roomID) {
  const owned = rooms.find(item => item.id === roomID);
  check(owned, 'cleanup_only_owned_room');
  if (owned.closed) return;
  await act(clients[0], owned.id, 'close_room');
  owned.closed = true;
  report.ownedRooms.find(item => item.id === roomID).closed = true;
  persist();
}
async function playing(allChance, noneChance) {
  const created = await ok(clients[0], bodyFor(null, 'create_room', {
    player: { name: 'FAN QA Host', client_capabilities: caps }, client_capabilities: caps,
  }));
  const roomID = created.room.id;
  rooms.push({ id: roomID, closed: false });
  report.ownedRooms.push({ id: roomID, closed: false });
  persist();
  for (const actor of clients.slice(1)) await ok(actor, {
    action: 'join_room', request_id: randomUUID(), room_code: created.room.code,
    join_membership_id: randomUUID(), client_capabilities: caps,
    player: { name: 'FAN QA Peer', client_capabilities: caps },
  });
  const lobby = await read(clients[0], roomID);
  check(lobby.players.length === 4, 'four_synthetic_players_joined');
  await ok(clients[0], bodyFor(lobby, 'update_lobby_state', {
    mutation_id: randomUUID(), expected_revision: lobby.lobby_revision,
    state: {
      game_mode: 'questions', game_duration_seconds: 900, lobby_spy_count: 1, spies_know_each_other: false,
      fan_mode_enabled: true, fan_all_spies_chance: allChance, fan_no_spies_chance: noneChance,
      lobby_word_source: 'manual', lobby_source_pack_id: '', lobby_source_name: 'FAN synthetic smoke words',
      lobby_theme: '', lobby_category: 'OBJECTS', lobby_word_count: 4, lobby_word_count_mode: 'custom',
      lobby_word_pool: ['Compass', 'Lantern', 'Bridge', 'Garden'].map(word => ({ id: randomUUID(), word, enabled: true })),
    },
  }));
  await act(clients[0], roomID, 'begin_ready_check');
  for (const actor of clients) await act(actor, roomID, 'toggle_ready');
  const armed = (await act(clients[0], roomID, 'arm_roulette')).room;
  const remaining = Date.parse(armed.intro_started_at) + 3_100 - Date.now();
  if (remaining > 0) await new Promise(resolve => setTimeout(resolve, remaining));
  await act(clients[1], roomID, 'complete_game_start');
  for (const actor of clients) await act(actor, roomID, 'mark_role_card_read');
  const views = await Promise.all(clients.map(actor => read(actor, roomID)));
  let spies = 0;
  for (const [index, view] of views.entries()) {
    check(view.status === 'playing' && Boolean(view.game_started_at), 'fan_round_remains_playing');
    check(view.fan_mode_enabled === true, 'fan_settings_persisted');
    check(!Object.hasOwn(view, 'fan_scenario') && !Object.hasOwn(view, 'fan_result_reason'), 'scenario_hidden_before_result');
    check(view.exclusion_vote_threshold === 3, 'fixed_player_threshold');
    check(view.spy_emails.length <= 1 && (view.revealed_spy_emails ?? []).length === 0, 'other_roles_hidden');
    const isSpy = view.spy_emails.includes(clients[index].email);
    if (isSpy) spies += 1;
    check(isSpy ? view.word === 'CLASSIFIED' : view.word !== 'CLASSIFIED', 'own_role_word_projection');
  }
  const scenario = spies === 4 ? 'all_spies' : spies === 0 ? 'no_spies' : 'standard';
  check(scenario !== 'standard' || spies === 1, 'valid_fan_assignment');
  const room = views[0];
  Object.assign(report.ownedRooms.find(item => item.id === roomID), { matchID: room.match_id, scenario });
  persist();
  const guess = await clients[0].send(bodyFor(room, 'submit_spy_guess', { guess: 'Compass' }));
  check(guess.status !== 200 && guess.body.code === 'fan_guess_disabled', 'word_guess_disabled_in_fan_mode');
  return { room, views, scenario };
}
async function selectedScenario(wanted) {
  const probabilities = wanted === 'all_spies' ? [99, 1] : wanted === 'no_spies' ? [1, 99] : [0, 0];
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const result = await playing(...probabilities);
    if (result.scenario === wanted) return { ...result, attempts: attempt };
    await close(result.room.id);
  }
  check(false, 'desired_scenario_not_sampled_in_three_attempts');
}
async function openVote(room) {
  for (const actor of clients.slice(0, 3)) await act(actor, room, 'request_vote');
  const voting = await read(clients[0], room);
  check(Boolean(voting.detective_vote_round_id), 'vote_round_opened');
  return voting.detective_vote_round_id;
}
async function vote(actor, room, target, round) {
  return act(actor, room, 'cast_detective_vote', { target_email: target, expected_vote_round_id: round });
}
async function verifyResult(room, winner, reason, scenario, expectedWins) {
  const final = await read(clients[0], room);
  check(final.status === 'finished' && final.winner === winner, `winner_${winner}`);
  if (reason) check(final.fan_result_reason === reason, `reason_${reason}`);
  check(final.fan_scenario === scenario, 'scenario_revealed_after_finish');
  for (const [index, actor] of clients.entries()) {
    const history = await ok(actor, { action: 'get_history' });
    const rows = history.history.filter(item => item.match_id === final.match_id);
    check(rows.length === 1, 'one_personal_result_per_match');
    check(rows[0].ranked === false && rows[0].fan_mode_enabled === true, 'fan_result_never_ranked');
    check(rows[0].won === expectedWins[index], 'per_player_win_correct');
    check(rows[0].fan_scenario === scenario, 'history_scenario_correct');
  }
  return { roomID: final.id, matchID: final.match_id, scenario, winner, reason: final.fan_result_reason ?? '', historyRows: 4, ranked: false };
}
async function run(name, operation) {
  const began = Date.now();
  try {
    const metrics = await operation();
    report.tests.push({ name, status: 'passed', durationMs: Date.now() - began, metrics });
    console.log(JSON.stringify({ test: name, status: 'passed' }));
  } catch (error) {
    report.tests.push({ name, status: 'failed', durationMs: Date.now() - began, error: safeError(error) });
    console.log(JSON.stringify({ test: name, status: 'failed', error: safeError(error) }));
  } finally {
    for (const owned of rooms.filter(item => !item.closed)) {
      try { await close(owned.id); }
      catch (error) { report.cleanupErrors.push({ roomID: owned.id, ...safeError(error) }); }
    }
    persist();
  }
}

try {
  for (const actor of credentials) clients.push(await client(actor));
  check(new Set(clients.map(actor => actor.id)).size === 4, 'four_independent_auth_users');
  for (const scenario of ['all_spies', 'no_spies']) await run(`${scenario}_correct_unanimous_vote`, async () => {
    const { room, attempts } = await selectedScenario(scenario);
    const round = await openVote(room), target = scenario === 'all_spies' ? allTarget : noneTarget;
    for (const actor of clients.slice(0, 3)) {
      await vote(actor, room, target, round);
      check((await read(clients[0], room)).status === 'playing', 'concept_waits_for_every_vote');
    }
    const finalBody = bodyFor(await read(clients[3], room), 'cast_detective_vote', { target_email: target, expected_vote_round_id: round });
    const final = await ok(clients[3], finalBody);
    stage = 'final_vote_idempotent_retry';
    assert.deepEqual(await ok(clients[3], finalBody), final);
    return { ...await verifyResult(room, 'all', 'correct_concept', scenario, [true, true, true, true]), attempts, finalVoteRetry: true };
  });
  await run('standard_fan_correct_player_accusation', async () => {
    const { room, views } = await selectedScenario('standard');
    const spyIndex = views.findIndex((view, index) => view.spy_emails.includes(clients[index].email));
    const round = await openVote(room);
    const voters = clients.filter((_, index) => index !== spyIndex);
    for (const actor of voters.slice(0, 2)) {
      await vote(actor, room, clients[spyIndex].email, round);
      check((await read(clients[0], room)).status === 'playing', 'player_waits_for_threshold');
    }
    await vote(voters[2], room, clients[spyIndex].email, round);
    return verifyResult(room, 'detectives', null, 'standard', clients.map((_, index) => index !== spyIndex));
  });
  await run('wrong_unanimous_concept_system_wins', async () => {
    const { room } = await selectedScenario('standard'), round = await openVote(room);
    for (const actor of clients) await vote(actor, room, noneTarget, round);
    return verifyResult(room, 'system', 'wrong_concept', 'standard', [false, false, false, false]);
  });
  await run('anomalous_player_accusation_system_wins', async () => {
    const { room, scenario } = await playing(99, 1), round = await openVote(room);
    for (const actor of clients.slice(1)) await vote(actor, room, clients[0].email, round);
    return verifyResult(room, 'system', 'wrong_accusation', scenario, [false, false, false, false]);
  });
  await run('split_votes_continue_and_duplicate_ballot_rejected', async () => {
    const { room } = await playing(99, 1), round = await openVote(room);
    await vote(clients[0], room, allTarget, round);
    const duplicate = await clients[0].send(bodyFor(room, 'cast_detective_vote', { target_email: noneTarget, expected_vote_round_id: round }));
    check(duplicate.status !== 200 && duplicate.body.code === 'detective_vote_already_cast', 'conflicting_second_vote_rejected');
    await vote(clients[1], room, noneTarget, round);
    await vote(clients[2], room, allTarget, round);
    await vote(clients[3], room, noneTarget, round);
    const final = await read(clients[0], room);
    check(final.status === 'playing' && !final.winner && !final.detective_vote_round_id, 'split_vote_continues_round');
    check(final.eliminated_emails.length === 0, 'split_vote_eliminates_nobody');
    for (const actor of clients) {
      const history = await ok(actor, { action: 'get_history' });
      check(!history.history.some(item => item.match_id === final.match_id), 'split_vote_writes_no_result');
    }
    return { roomID: final.id, matchID: final.match_id, status: final.status, historyRows: 0, duplicateRejected: true };
  });
} catch (error) {
  report.setupError = safeError(error);
  console.log(JSON.stringify({ status: 'setup_failed', error: safeError(error) }));
} finally {
  for (const owned of rooms.filter(item => !item.closed)) {
    try { await close(owned.id); }
    catch (error) { report.cleanupErrors.push({ roomID: owned.id, ...safeError(error) }); }
  }
  await Promise.allSettled(clients.map(actor => actor.sdk.removeAllChannels()));
  report.durationMs = Date.now() - started;
  report.passed = report.tests.filter(test => test.status === 'passed').length;
  report.failed = report.tests.filter(test => test.status === 'failed').length;
  report.status = !report.setupError && !report.failed && !report.cleanupErrors.length && report.tests.length === 6 ? 'passed' : 'failed';
  persist();
  console.log(JSON.stringify({ status: report.status, passed: report.passed, failed: report.failed, cleanupErrors: report.cleanupErrors.length, durationMs: report.durationMs, reportPath }));
  process.exitCode = report.status === 'passed' ? 0 : 1;
}
