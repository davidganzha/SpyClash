import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { cloudTestConfig, requireAllowedTestTarget, requireLoopback, eventually } from '../client/game-client.mjs';
import { loadTestFixture, testEnvironment } from './test-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const env = testEnvironment({ SUPABASE_TEST_CONFIG_FILE: resolve(root, '.local/cloud-env.json'), ...process.env });
const config = cloudTestConfig(env);
const fixture = loadTestFixture(config, env.SUPABASE_TEST_ACTORS_FILE ?? resolve(root, '.local/cloud-actors.json'));
const credentials = ['js1', 'js2', 'js3', 'js4', 'js5', 'js6'].map(id => {
  const actor = fixture.actors.find(item => item.id === id);
  assert.ok(actor, `Missing synthetic fixture ${id}`); return actor;
});
const endpoint = `${config.url}/functions/v1/full-game-core`;
requireAllowedTestTarget(endpoint, config);
if (process.argv.includes('--check')) {
  console.log(JSON.stringify({ valid: true, projectRef: config.projectRef, endpoint, syntheticActors: credentials.length, credentials: 'memory-only', mutations: false }));
  process.exit(0);
}

const clients = [], rooms = [], packs = [];
const report = { projectRef: config.projectRef, endpoint, startedAt: new Date().toISOString(), tests: [], cleanupErrors: [], credentialsPersisted: false };
const started = Date.now();
let stage = 'initializing';
const caps = ['multi_spy_v1'];
const turns = new Set(['advance_question', 'mark_answer_heard', 'continue_round', 'start_association', 'advance_association', 'stop_association_spin']);
const safeError = error => ({ kind: /^[\w-]+$/.test(error?.name || '') ? error.name : 'Error', code: /^[\w-]+$/.test(error?.code || '') ? error.code : 'check_failed', stage });
const check = (condition, label) => { stage = label; assert.ok(condition); };
async function settle(promises) {
  const results = await Promise.allSettled(promises);
  const rejected = results.find(result => result.status === 'rejected');
  if (rejected) throw rejected.reason;
  return results.map(result => result.value);
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
  await sdk.realtime.setAuth(data.session.access_token);
  return {
    id: data.user.id, email: `${data.user.id.toLowerCase()}@example.test`, sdk,
    async send(body, transportURL) {
      stage = `http_${body.action}`;
      const target = transportURL ?? endpoint;
      if (transportURL) requireLoopback(target, 'Fault transport'); else requireAllowedTestTarget(target, config);
      const response = await fetch(target, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000), headers: {
        Authorization: `Bearer ${data.session.access_token}`, apikey: config.anonKey, 'Content-Type': 'application/json',
      }, body: JSON.stringify(body) });
      return { status: response.status, body: await response.json() };
    },
  };
}
async function ok(actor, body, transportURL) {
  const result = await actor.send(body, transportURL);
  if (result.status !== 200) { const error = new Error('Game command failed'); error.code = result.body.code || `http_${result.status}`; throw error; }
  return result.body;
}
async function read(actor, room) { return (await ok(actor, { action: 'get_room', room_id: typeof room === 'string' ? room : room.id })).room; }
function bodyFor(room, action, values = {}, requestID = randomUUID()) {
  return structuredClone({ action, request_id: requestID, ...(room ? { room_id: room.id } : {}),
    ...(['arm_roulette', 'toggle_ready', 'begin_ready_check'].includes(action) ? { expected_lobby_revision: room.lobby_revision } : {}),
    ...(['leave_room', 'close_room', 'toggle_ready'].includes(action) ? { expected_membership_id: room.viewer_membership_id } : {}),
    ...(turns.has(action) ? { expected_revision: room.room_revision } : {}),
    ...(room?.match_id ? { expected_match_id: room.match_id } : {}), ...values });
}
async function act(actor, room, action, values = {}) { return ok(actor, bodyFor(await read(actor, room), action, values)); }
async function lobby(team, mode = 'questions', spyCount = 1) {
  const created = await ok(team[0], bodyFor(null, 'create_room', { player: { name: 'Cloud Core Host', client_capabilities: caps }, client_capabilities: caps }));
  rooms.push({ host: team[0], id: created.room.id });
  await settle(team.slice(1).map(actor => ok(actor, { action: 'join_room', request_id: randomUUID(), room_code: created.room.code, join_membership_id: randomUUID(), client_capabilities: caps, player: { name: 'Cloud Core Peer', client_capabilities: caps } })));
  const room = await read(team[0], created.room);
  check(room.players.length === team.length, 'all_concurrent_joins_retained');
  return (await ok(team[0], bodyFor(room, 'update_lobby_state', { mutation_id: randomUUID(), expected_revision: room.lobby_revision, state: {
    game_mode: mode, game_duration_seconds: 900, lobby_spy_count: spyCount, spies_know_each_other: false,
    lobby_word_source: 'manual', lobby_source_pack_id: '', lobby_source_name: 'Cloud smoke words', lobby_theme: '', lobby_category: 'OBJECTS',
    lobby_word_count: 4, lobby_word_count_mode: 'custom', lobby_word_pool: ['Compass', 'Lantern', 'Bridge', 'Garden'].map(word => ({ id: randomUUID(), word, enabled: true })),
  } }))).room;
}
async function start(team, room) {
  await act(team[0], room, 'begin_ready_check');
  await settle(team.map(actor => act(actor, room, 'toggle_ready')));
  const ready = await read(team[0], room); check(ready.ready_players.length === team.length, 'all_concurrent_readiness_retained');
  const frozen = bodyFor(ready, 'arm_roulette');
  const starts = await settle(Array.from({ length: 6 }, () => ok(team[0], frozen)));
  stage = 'duplicate_arm_exact_response'; starts.forEach(result => assert.deepEqual(result, starts[0]));
  const remaining = Date.parse(starts[0].room.intro_started_at) + 3_000 - Date.now();
  if (remaining > 0) await new Promise(resolve => setTimeout(resolve, remaining + 50));
  const playing = (await act(team[1], room, 'complete_game_start')).room;
  check(!playing.game_started_at, 'no_timer_before_card_acknowledgements');
  await settle(team.map(actor => act(actor, room, 'mark_role_card_read')));
  const current = await read(team[0], room); check(Boolean(current.game_started_at), 'server_timer_after_last_card'); return current;
}

async function faultProxy() {
  const target = requireAllowedTestTarget(endpoint, config);
  let dropID, port = 0;
  const stats = { dropped: 0, upstreamStatus: null };
  const server = http.createServer(async (request, response) => {
    const destination = new URL(request.url, target);
    if (!request.url.startsWith('/') || request.url.startsWith('//') || destination.origin !== target.origin || destination.pathname !== target.pathname || destination.search || destination.username || destination.password) { response.writeHead(400).end(); return; }
    requireAllowedTestTarget(destination.href, config);
    const chunks = []; let size = 0;
    for await (const chunk of request) { size += chunk.length; if (size > 131_072) { response.writeHead(413).end(); return; } chunks.push(chunk); }
    const body = Buffer.concat(chunks); let shouldDrop;
    try { shouldDrop = dropID && JSON.parse(body.toString()).request_id === dropID; } catch { response.writeHead(400).end(); return; }
    if (shouldDrop) dropID = null;
    const upstream = https.request(destination, { method: 'POST', timeout: 30_000, headers: { ...request.headers, host: target.host, connection: 'close' } }, incoming => {
      const chunks = []; incoming.on('data', chunk => chunks.push(chunk)); incoming.on('end', () => {
        if (shouldDrop && incoming.statusCode >= 200 && incoming.statusCode < 300) { stats.dropped += 1; stats.upstreamStatus = incoming.statusCode; response.destroy(); return; }
        response.writeHead(incoming.statusCode, incoming.headers).end(Buffer.concat(chunks));
      });
    });
    upstream.on('error', () => response.destroy()); upstream.on('timeout', () => { upstream.destroy(); response.destroy(); }); upstream.end(body);
  });
  const open = () => new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', () => { server.off('error', reject); port = server.address().port; resolve(); }); });
  const close = async () => { if (!server.listening) return; const stopped = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await stopped; };
  await open();
  return { url: `http://127.0.0.1:${port}${target.pathname}`, stats, drop(id) { dropID = id; }, close, open };
}
async function run(name, operation) {
  const began = Date.now();
  try { const metrics = await operation(); report.tests.push({ name, status: 'passed', durationMs: Date.now() - began, metrics }); console.log(JSON.stringify({ test: name, status: 'passed' })); }
  catch (error) { report.tests.push({ name, status: 'failed', durationMs: Date.now() - began, error: safeError(error) }); console.log(JSON.stringify({ test: name, status: 'failed', error: safeError(error) })); }
}

try {
  for (const actor of credentials) clients.push(await client(actor));
  check(new Set(clients.map(actor => actor.id)).size === 6, 'six_independent_auth_users');
  await run('concurrent_six_client_start_and_private_projections', async () => {
    const room = await lobby(clients, 'questions', 2); await start(clients, room);
    const views = await settle(clients.map(actor => read(actor, room))); let ownSpies = 0;
    views.forEach((view, index) => {
      const isSpy = view.spy_emails.includes(clients[index].email);
      if (isSpy) { ownSpies += 1; check(view.spy_emails.length === 1 && view.word === 'CLASSIFIED', 'own_spy_only_and_secret_redacted'); }
      else check(view.spy_emails.length === 0 && view.word !== 'CLASSIFIED', 'civilian_has_word_without_spy_identity');
      check(view.lobby_word_pool.length === 0, 'active_lobby_secret_duplicates_redacted');
      for (const key of ['terminal_intent', 'participant_user_ids', 'departed_player_emails']) check(!Object.hasOwn(view, key), 'private_internals_absent');
    });
    check(ownSpies === 2, 'two_frozen_spies');
    return { clients: 6, visibleOwnRoleCount: ownSpies, duplicateStartAttempts: 6, convergedRevision: views[0].room_revision };
  });
  await run('lost_https_acknowledgement_retry_after_peer_write_and_offline_transport', async () => {
    const team = clients.slice(0, 3), room = await lobby(team); await act(team[0], room, 'begin_ready_check');
    const proxy = await faultProxy();
    try {
      const before = await read(team[0], room), frozen = bodyFor(before, 'toggle_ready');
      proxy.drop(frozen.request_id); stage = 'real_committed_ack_drop'; await assert.rejects(team[0].send(frozen, proxy.url));
      check(proxy.stats.dropped === 1 && proxy.stats.upstreamStatus === 200, 'upstream_commit_before_downstream_drop');
      const committed = await read(team[1], room); await act(team[1], room, 'toggle_ready');
      const changed = await read(team[1], room), replay = await ok(team[0], frozen, proxy.url);
      check(replay.revision === committed.room_revision, 'original_receipt_revision_after_other_writer');
      check((await read(team[0], room)).room_revision === changed.room_revision, 'replay_does_not_reapply');
      check((await team[0].send({ ...frozen, action: 'return_to_waiting' })).body.code === 'request_id_reused', 'changed_body_reuse_rejected');
      const pending = bodyFor(await read(team[2], room), 'toggle_ready');
      await proxy.close(); stage = 'real_refused_connection'; await assert.rejects(team[2].send(pending, proxy.url));
      await proxy.open(); const recovered = await ok(team[2], pending, proxy.url);
      stage = 'offline_intent_exact_replay'; assert.deepEqual(await ok(team[2], pending), recovered);
      return { droppedResponses: proxy.stats.dropped, immutableRetry: true, offlineRetry: true, convergedRevision: recovered.revision };
    } finally { await proxy.close(); }
  });
  await run('questions_eight_turns_results_spy_guess_history_and_replay', async () => {
    const team = clients.slice(0, 3), room = await lobby(team); await start(team, room);
    for (let index = 0; index < 8; index += 1) {
      const current = await read(team[0], room), actor = team.find(item => item.email === current.current_asker_email);
      await act(actor, room, index % 2 ? 'mark_answer_heard' : 'advance_question');
    }
    check((await read(team[0], room)).question_phase === 'results', 'eighth_question_results');
    await act(team[1], room, 'continue_round');
    const views = await settle(team.map(actor => read(actor, room))), matchID = views[0].match_id;
    const spy = team.find((actor, index) => views[index].spy_emails.includes(actor.email));
    const finishBody = bodyFor(await read(spy, room), 'submit_spy_guess', { guess: 'Not in this synthetic word pool' });
    const completed = await ok(spy, finishBody); check(completed.room.winner === 'detectives', 'incorrect_guess_detective_win');
    stage = 'terminal_exact_receipt_replay'; assert.deepEqual(await ok(spy, finishBody), completed);
    for (const actor of team) {
      const history = await ok(actor, { action: 'get_history' }); check(history.history.filter(item => item.match_id === matchID).length === 1, 'one_personal_result_per_match');
    }
    await settle(team.map(actor => act(actor, room, 'vote_play_again', { expected_match_id: matchID })));
    check((await read(team[0], room)).status === 'roulette', 'unanimous_replay_auto_armed');
    return { questions: 8, historyRowsVerified: 3, terminalRetry: true, replayAutoStarted: true };
  });
  await run('associations_round_and_detective_threshold', async () => {
    const team = clients.slice(3), room = await lobby(team, 'associations'); await start(team, room); await act(team[0], room, 'start_association');
    const speakers = new Set();
    for (let index = 0; index < 3; index += 1) {
      const current = await read(team[0], room), actor = team.find(item => item.email === current.current_asker_email); speakers.add(actor.id);
      await act(actor, room, 'stop_association_spin'); await act(actor, room, 'advance_association');
    }
    check(speakers.size === 3 && (await read(team[0], room)).round_number === 2, 'each_association_speaker_once');
    await settle(team.slice(0, 2).map(actor => act(actor, room, 'request_vote')));
    const views = await settle(team.map(actor => read(actor, room))), spy = team.find((actor, index) => views[index].spy_emails.includes(actor.email));
    const round = views[0].detective_vote_round_id;
    for (const actor of team.filter(item => item !== spy)) await act(actor, room, 'cast_detective_vote', { target_email: spy.email, expected_detective_vote_round_id: round });
    const finished = await read(team[0], room); check(finished.winner === 'detectives' && finished.detective_votes.length === 2, 'n_minus_s_threshold_not_plurality');
    return { distinctSpeakers: 3, terminalBallots: 2, thresholdPreserved: true };
  });
  await run('saved_word_packs_owner_isolation_and_private_leaderboard_ids', async () => {
    const host = clients[0], created = await ok(host, bodyFor(null, 'create_word_pack', { pack: { name: 'Cloud smoke pack', category: 'Objects', words: ['Museum', 'Station', 'Forest'] } }));
    packs.push({ host, id: created.pack.id });
    check(created.receipt?.request_id, 'pack_commit_receipt_present');
    check((await ok(host, { action: 'word_packs' })).packs.some(pack => pack.id === created.pack.id), 'saved_pack_listed');
    check((await clients[1].send({ action: 'get_word_pack', pack_id: created.pack.id })).status === 404, 'other_actor_cannot_read_private_pack');
    await ok(host, bodyFor(null, 'update_word_pack', { pack_id: created.pack.id, pack: { name: 'Cloud smoke updated', category: 'Objects', words: ['Museum', 'Station', 'Harbour'] } }));
    check((await ok(host, { action: 'get_word_pack', pack_id: created.pack.id })).pack.words.length === 3, 'saved_pack_update_visible');
    const ranked = await ok(host, { action: 'get_leaderboard' }); check(Array.isArray(ranked.entries), 'original_leaderboard_entries_contract');
    for (const entry of ranked.entries) {
      check(/^operative:/.test(entry.id), 'opaque_rank_identity');
      check(!clients.some(actor => JSON.stringify(entry).includes(actor.id) || JSON.stringify(entry).includes(actor.email)), 'leaderboard_no_auth_identity');
    }
    return { ownerIsolation: true, updatedWordCount: 3, leaderboardEntries: ranked.entries.length };
  });
  await run('six_actual_wal_subscriptions_and_reconnected_socket', async () => {
    const room = await lobby(clients), watches = [];
    const watch = async actor => {
      const revisions = []; let resolveReady, rejectReady;
      const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
      const timer = setTimeout(() => rejectReady(new Error('Realtime timeout')), 25_000);
      const channel = actor.sdk.channel(`full-cloud-${randomUUID()}`, { config: { postgres_changes_options: { wait: true, timeout: 20_000 } } })
        .on('postgres_changes', { event: '*', schema: 'public', table: 'full_game_room_signals', filter: `room_id=eq.${room.id}` }, event => { revisions.push(Number(event.new.revision)); })
        .subscribe(status => { if (status === 'SUBSCRIBED') { clearTimeout(timer); resolveReady(); } else if (['CHANNEL_ERROR', 'TIMED_OUT'].includes(status)) { clearTimeout(timer); rejectReady(new Error('Realtime subscription failed')); } });
      const value = { actor, channel, revisions }; watches.push(value);
      try { await ready; } finally { clearTimeout(timer); }
      return value;
    };
    try {
      await settle(clients.map(watch));
      const updated = (await act(clients[0], room, 'update_game_duration', { game_duration_seconds: 180 })).room;
      stage = 'six_actual_wal_events'; await eventually(() => watches.every(item => item.revisions.includes(updated.room_revision)), { timeout: 20_000, message: 'WAL event missing' });
      const disconnected = watches[5]; await disconnected.actor.sdk.removeChannel(disconnected.channel); await disconnected.actor.sdk.realtime.disconnect();
      const missed = (await act(clients[0], room, 'update_game_duration', { game_duration_seconds: 240 })).room;
      check(!disconnected.revisions.includes(missed.room_revision), 'disconnected_socket_misses_signal');
      const recovered = await watch(disconnected.actor);
      check((await read(disconnected.actor, room)).room_revision === missed.room_revision, 'reconnect_snapshot_recovers_missed_revision');
      const next = (await act(clients[0], room, 'update_game_duration', { game_duration_seconds: 300 })).room;
      stage = 'reconnected_actual_wal'; await eventually(() => recovered.revisions.includes(next.room_revision), { timeout: 20_000, message: 'Reconnected WAL event missing' });
      return { subscribedClients: 6, actualWalReceivedBy: 6, reconnectedWal: true, convergedRevision: next.room_revision };
    } finally { await settle(watches.map(item => item.actor.sdk.removeChannel(item.channel))); }
  });
} catch (error) {
  report.setupError = safeError(error); console.log(JSON.stringify({ status: 'setup_failed', error: safeError(error) }));
} finally {
  for (const item of rooms) {
    try { const room = await read(item.host, item.id); if (room) await ok(item.host, bodyFor(room, 'close_room')); }
    catch (error) { report.cleanupErrors.push({ resource: 'owned_test_room', ...safeError(error) }); }
  }
  for (const item of packs) {
    try { await ok(item.host, bodyFor(null, 'delete_word_pack', { pack_id: item.id })); }
    catch (error) { report.cleanupErrors.push({ resource: 'owned_test_pack', ...safeError(error) }); }
  }
  await Promise.allSettled(clients.map(async actor => { await actor.sdk.removeAllChannels(); await actor.sdk.realtime.disconnect(); }));
  report.durationMs = Date.now() - started; report.passed = report.tests.filter(test => test.status === 'passed').length;
  report.failed = report.tests.filter(test => test.status === 'failed').length;
  report.status = !report.setupError && !report.failed && !report.cleanupErrors.length && report.tests.length === 6 ? 'passed' : 'failed';
  mkdirSync(resolve(root, '.local'), { recursive: true, mode: 0o700 });
  const path = resolve(root, '.local/full-core-cloud-results.json');
  writeFileSync(path, JSON.stringify(report, null, 2) + '\n', { mode: 0o600 }); chmodSync(path, 0o600);
  console.log(JSON.stringify({ status: report.status, passed: report.passed, failed: report.failed, cleanupErrors: report.cleanupErrors.length, durationMs: report.durationMs, report: '.local/full-core-cloud-results.json' }));
  process.exitCode = report.status === 'passed' ? 0 : 1;
}
