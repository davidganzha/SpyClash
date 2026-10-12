import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import http from 'node:http';
import { createClient } from '@supabase/supabase-js';
import { localConfig, requireLoopback } from '../../client/game-client.mjs';

export const config = localConfig();
export const serviceURL = requireLoopback(process.env.FULL_CORE_URL, 'FULL_CORE_URL').href;
assert.equal(new URL(serviceURL).protocol, 'http:', 'Local full-core tests require HTTP on loopback');
requireLoopback(process.env.DATABASE_URL, 'DATABASE_URL');
const capabilities = ['multi_spy_v1'];
const turnActions = new Set(['advance_question', 'advance_association', 'start_association', 'stop_association_spin', 'mark_answer_heard', 'continue_round']);

export async function createActor(index) {
  const sdk = createClient(config.url, config.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: (url, options) => {
      requireLoopback(String(url), 'Auth/Data API URL');
      return fetch(url, { ...options, redirect: 'error', signal: options?.signal ?? AbortSignal.timeout(15_000) });
    } },
  });
  const { data, error } = await sdk.auth.signUp({
    email: `full-core-${randomUUID()}@example.test`, password: `${randomUUID()}!Aa7`,
    options: { data: { full_name: `Core Player ${index + 1}` } },
  });
  if (error) throw new Error(`Synthetic local Auth failed: ${error.code}`);
  assert.ok(data.session && data.user, 'Local Auth must confirm synthetic users');
  await sdk.realtime.setAuth(data.session.access_token);
  // Credentials remain in this in-memory closure, never fixture files or logs.
  return {
    id: data.user.id, email: `${data.user.id.toLowerCase()}@example.test`, name: `Core Player ${index + 1}`, sdk,
    async send(body, { url = serviceURL, anonymous = false } = {}) {
      requireLoopback(url, 'Game service URL');
      const response = await fetch(url, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(15_000),
        headers: { 'Content-Type': 'application/json', ...(anonymous ? {} : { Authorization: `Bearer ${data.session.access_token}` }) },
        body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    },
    async close() { await sdk.removeAllChannels(); await sdk.realtime.disconnect(); },
  };
}

export function intent(actor, room, action, values = {}, requestID = randomUUID()) {
  return structuredClone({
    action, request_id: requestID, ...(room ? { room_id: room.id } : {}),
    ...(['arm_roulette', 'begin_ready_check', 'toggle_ready'].includes(action) ? { expected_lobby_revision: room.lobby_revision } : {}),
    ...(['leave_room', 'close_room', 'toggle_ready'].includes(action) ? { expected_membership_id: room.viewer_membership_id } : {}),
    ...(turnActions.has(action) ? { expected_revision: room.room_revision } : {}),
    ...(room?.match_id ? { expected_match_id: room.match_id } : {}),
    ...values,
  });
}

export async function accepted(actor, body, options) {
  const result = await actor.send(body, options);
  assert.equal(result.status, 200, `${body.action} rejected: ${result.body.code}: ${result.body.message}`);
  return result.body;
}
export async function snapshot(actor, room) {
  return (await accepted(actor, { action: 'get_room', room_id: typeof room === 'string' ? room : room.id })).room;
}
export async function act(actor, room, action, values = {}, options) {
  const current = await snapshot(actor, room);
  return accepted(actor, intent(actor, current, action, values), options);
}
export async function lobby(actors, settings = {}) {
  const created = await accepted(actors[0], intent(actors[0], null, 'create_room', {
    player: { name: actors[0].name, client_capabilities: capabilities }, client_capabilities: capabilities,
  }));
  assert.match(created.room.code, /^[A-Z0-9]{6}$/);
  await Promise.all(actors.slice(1).map(actor => accepted(actor, {
    action: 'join_room', request_id: randomUUID(), room_code: created.room.code,
    join_membership_id: randomUUID(), client_capabilities: capabilities,
    player: { name: actor.name, client_capabilities: capabilities },
  })));
  const room = await snapshot(actors[0], created.room);
  assert.equal(room.players.length, actors.length);
  const state = {
    game_mode: 'questions', game_duration_seconds: 900, lobby_spy_count: 1, spies_know_each_other: false,
    lobby_word_source: 'manual', lobby_source_pack_id: '', lobby_source_name: 'Integration words',
    lobby_theme: '', lobby_category: 'OBJECTS', lobby_word_count: 4, lobby_word_count_mode: 'custom',
    lobby_word_pool: ['Compass', 'Lantern', 'Bridge', 'Garden'].map(word => ({ id: randomUUID(), word, enabled: true })),
    ...settings,
  };
  return (await accepted(actors[0], intent(actors[0], room, 'update_lobby_state', {
    mutation_id: randomUUID(), expected_revision: room.lobby_revision, state,
  }))).room;
}
export async function ready(actors, room) {
  await act(actors[0], room, 'begin_ready_check');
  await Promise.all(actors.map(actor => act(actor, room, 'toggle_ready')));
  return snapshot(actors[0], room);
}
export async function playing(actors, settings = {}) {
  const room = await lobby(actors, settings);
  await ready(actors, room);
  const armed = (await act(actors[0], room, 'arm_roulette')).room;
  // Honor the actual server-stamped intro deadline; no fixture bypass of start.
  const remaining = Date.parse(armed.intro_started_at) + 3_000 - Date.now();
  if (remaining > 0) await new Promise(resolve => setTimeout(resolve, remaining + 40));
  const started = (await act(actors[1], room, 'complete_game_start')).room;
  assert.equal(started.status, 'playing');
  assert.ok(!started.game_started_at, 'Timer remains unstarted until every card is read');
  await Promise.all(actors.map(actor => act(actor, room, 'mark_role_card_read')));
  const running = await snapshot(actors[0], room);
  assert.ok(running.game_started_at, 'Last active card read starts server timer');
  return running;
}

/** Only real loopback forwarding. A selected completed 2xx is dropped downstream. */
export async function commandProxy(upstream = serviceURL) {
  const target = requireLoopback(upstream);
  assert.equal(target.protocol, 'http:');
  let selectedID, port = 0;
  const stats = { dropped: 0, committedStatus: null };
  const server = http.createServer(async (request, response) => {
    if (!request.url?.startsWith('/') || request.url.startsWith('//')) { response.writeHead(400).end(); return; }
    const destination = new URL(request.url, target);
    if (destination.origin !== target.origin || destination.username || destination.password) { response.writeHead(400).end(); return; }
    const chunks = []; let size = 0;
    for await (const chunk of request) {
      size += chunk.length;
      if (size > 131_072) { response.writeHead(413).end(); return; }
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    let shouldDrop = false;
    try { shouldDrop = Boolean(selectedID && JSON.parse(body.toString()).request_id === selectedID); }
    catch { response.writeHead(400).end(); return; }
    if (shouldDrop) selectedID = undefined;
    const outgoing = http.request(destination, {
      method: request.method, headers: { ...request.headers, host: target.host, connection: 'close' }, timeout: 15_000,
    }, incoming => {
      const reply = [];
      incoming.on('data', chunk => reply.push(chunk));
      incoming.on('end', () => {
        if (shouldDrop && incoming.statusCode >= 200 && incoming.statusCode < 300) {
          stats.dropped += 1; stats.committedStatus = incoming.statusCode; response.destroy(); return;
        }
        response.writeHead(incoming.statusCode, incoming.headers).end(Buffer.concat(reply));
      });
    });
    outgoing.on('error', () => response.destroy());
    outgoing.on('timeout', () => { outgoing.destroy(); response.destroy(); });
    outgoing.end(body);
  });
  const start = () => new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => { server.off('error', reject); port = server.address().port; resolve(); });
  });
  const stop = async () => {
    if (!server.listening) return;
    const stopped = new Promise(resolve => server.close(resolve));
    server.closeAllConnections(); await stopped;
  };
  await start();
  return { url: `http://127.0.0.1:${port}${target.pathname}`, stats, drop(id) { selectedID = id; }, disconnect: stop, reconnect: start, close: stop };
}
