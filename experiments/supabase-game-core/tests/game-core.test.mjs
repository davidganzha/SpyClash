import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import pg from 'pg';
import { GameClient, eventually, localConfig, requireLoopback } from '../client/game-client.mjs';
import { faultProxy } from './fault-proxy.mjs';

const config = localConfig();

async function players(t, count, firstOptions) {
  const clients = [];
  t.after(async () => { await Promise.all(clients.map((client) => client.close())); });
  // Sequential signups avoid mistaking local Auth burst limits for game errors.
  for (let index = 0; index < count; index += 1) {
    const client = new GameClient(config, index === 0 ? firstOptions : undefined);
    clients.push(client);
    await client.signUp(`Player ${index + 1}`);
  }
  return clients;
}

async function lobby(clients, maxPlayers = 12) {
  const roomID = randomUUID();
  await clients[0].command(roomID, 'create_room', { name: clients[0].name, settings: { max_players: maxPlayers } });
  await Promise.all(clients.slice(1).map((client) => client.command(roomID, 'join_room', { name: client.name })));
  await Promise.all(clients.map((client) => client.snapshot(roomID)));
  return roomID;
}

async function ready(clients, roomID) {
  await Promise.all(clients.map((client) => client.snapshot(roomID)));
  await Promise.all(clients.map((client) => client.command(roomID, 'set_ready', { ready: true })));
}

async function playing(clients) {
  const roomID = await lobby(clients);
  await ready(clients, roomID);
  await clients[0].command(roomID, 'start_game');
  const snapshot = await clients[0].snapshot(roomID);
  return { roomID, matchID: snapshot.match_id };
}

function publicProjection(snapshot) {
  const { own_role, own_word, own_membership_id, ...shared } = snapshot;
  return shared;
}

function assertNoOtherSecrets(snapshot) {
  for (const key of ['spy_id', 'spy_user_id', 'spy_email', 'spy_emails', 'word', 'roles', 'secrets']) {
    assert.equal(Object.hasOwn(snapshot, key), false, `snapshot leaked ${key}`);
  }
  for (const player of snapshot.players) {
    assert.deepEqual(Object.keys(player).sort(), ['joined_at', 'membership_id', 'name', 'ready', 'user_id']);
  }
}

async function rejected(promise, message) {
  await assert.rejects(promise, (error) => error.message === message);
}

function assertInvisible(result, message) {
  assert.ok(result.error || (Array.isArray(result.data) && result.data.length === 0), message);
}

test('local-only safety refuses remote API and database targets before connecting', () => {
  assert.throws(() => requireLoopback('https://example.supabase.co'), /loopback/);
  assert.throws(() => localConfig({ SUPABASE_URL: config.url, SUPABASE_ANON_KEY: 'local', DATABASE_URL: 'postgres://example.com/db' }), /loopback/);
});

test('concurrent joins, readiness and competing starts preserve every player and one match', { timeout: 60_000 }, async (t) => {
  const clients = await players(t, 6);
  const roomID = await lobby(clients);
  const joined = await clients[0].snapshot(roomID);
  assert.equal(joined.players.length, 6);
  assert.equal(new Set(joined.players.map((player) => player.user_id)).size, 6);
  await ready(clients, roomID);
  const allReady = await clients[0].snapshot(roomID);
  assert.equal(allReady.players.filter((player) => player.ready).length, 6);
  assert.equal(allReady.revision, joined.revision + 6);
  const starts = await Promise.allSettled(Array.from({ length: 8 }, () => clients[0].command(roomID, 'start_game')));
  assert.equal(starts.filter((result) => result.status === 'fulfilled').length, 1);
  for (const result of starts.filter((result) => result.status === 'rejected')) assert.equal(result.reason.message, 'invalid_phase');
  const snapshots = await Promise.all(clients.map((client) => client.snapshot(roomID)));
  assert.equal(snapshots[0].phase, 'playing');
  assert.equal(snapshots[0].revision, allReady.revision + 1);
  assert.equal(new Set(snapshots.map((snapshot) => snapshot.match_id)).size, 1);
  assert.equal(snapshots.filter((snapshot) => snapshot.own_role === 'spy').length, 1);
  for (const snapshot of snapshots) {
    assert.deepEqual(publicProjection(snapshot), publicProjection(snapshots[0]));
    assertNoOtherSecrets(snapshot);
    if (snapshot.own_role === 'spy') assert.equal(snapshot.own_word, null);
    else assert.equal(typeof snapshot.own_word, 'string');
  }
});

test('capacity and expected revision are serialized under simultaneous commands', { timeout: 60_000 }, async (t) => {
  const clients = await players(t, 6);
  const roomID = await lobby([clients[0]], 3);
  const results = await Promise.allSettled(clients.slice(1).map((client) => client.command(roomID, 'join_room', { name: client.name })));
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 2);
  assert.equal(results.filter((result) => result.status === 'rejected' && result.reason.message === 'room_full').length, 3);
  const before = await clients[0].snapshot(roomID);
  assert.equal(before.players.length, 3);
  const writes = await Promise.allSettled([4, 5].map((max_players) => clients[0].command(roomID, 'update_settings', {
    settings: { max_players }, expected_revision: before.revision,
  })));
  assert.equal(writes.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(writes.filter((result) => result.status === 'rejected' && result.reason.message === 'stale_revision').length, 1);
  assert.equal((await clients[0].snapshot(roomID)).revision, before.revision + 1);
});

test('parallel retries return the durable original receipt; mismatched reuse is rejected', { timeout: 60_000 }, async (t) => {
  const [host, peer, third] = await players(t, 3);
  const roomID = randomUUID();
  const requestID = randomUUID();
  const payload = { name: host.name, settings: { max_players: 6 } };
  const receipts = await Promise.all(Array.from({ length: 16 }, () => host.command(roomID, 'create_room', payload, requestID)));
  for (const receipt of receipts) assert.deepEqual(receipt, receipts[0]);
  assert.equal((await host.snapshot(roomID)).players.length, 1);
  await peer.command(roomID, 'join_room', { name: peer.name });
  const beforeReplay = await host.snapshot(roomID);
  assert.deepEqual(await host.command(roomID, 'create_room', payload, requestID), receipts[0]);
  assert.equal((await host.snapshot(roomID)).revision, beforeReplay.revision);
  await rejected(host.command(roomID, 'create_room', { ...payload, name: 'Different' }, requestID), 'idempotency_mismatch');
  await rejected(host.command(randomUUID(), 'create_room', payload, requestID), 'idempotency_mismatch');
  await rejected(host.command(roomID, 'set_ready', { ready: true }, requestID), 'idempotency_mismatch');
  // A rejected transaction must not permanently poison its request ID.
  const failedStartID = randomUUID();
  await rejected(host.command(roomID, 'start_game', {}, failedStartID), 'not_enough_players');
  assert.deepEqual(await host.snapshot(roomID), beforeReplay);
  await third.command(roomID, 'join_room', { name: third.name });
  await ready([host, peer, third], roomID);
  assert.equal((await host.command(roomID, 'start_game', {}, failedStartID)).phase, 'playing');
});

test('lost HTTP acknowledgement after commit retries exactly once after a different writer', { timeout: 60_000 }, async (t) => {
  const proxy = await faultProxy(config.url);
  t.after(() => proxy.close());
  const [host, peer] = await players(t, 2, { transportURL: proxy.url });
  const roomID = await lobby([host, peer]);
  const before = await host.snapshot(roomID);
  const requestID = randomUUID();
  proxy.dropNextResponse(requestID);
  await assert.rejects(host.command(roomID, 'set_ready', { ready: true }, requestID));
  assert.equal(proxy.stats.droppedResponses, 1);
  assert.ok(proxy.stats.committedStatus >= 200 && proxy.stats.committedStatus < 300);
  assert.ok(host.pendingIDs.includes(requestID));
  const committed = await peer.snapshot(roomID);
  assert.equal(committed.revision, before.revision + 1);
  assert.equal(committed.players.find((player) => player.user_id === host.userID).ready, true);
  await peer.command(roomID, 'set_ready', { ready: true });
  const afterOtherWriter = await peer.snapshot(roomID);
  const recovered = await host.retry(requestID);
  assert.equal(recovered.revision, committed.revision);
  assert.equal(recovered.request_id, requestID);
  assert.deepEqual(publicProjection(await host.snapshot(roomID)), publicProjection(afterOtherWriter));
  assert.equal(host.pendingIDs.includes(requestID), false);
});

test('replaying an acknowledged leave after rejoin preserves the new membership and reveals no secrets', { timeout: 60_000 }, async (t) => {
  const [host, peer] = await players(t, 2);
  const roomID = await lobby([host, peer]);
  const leaveID = randomUUID();
  const receipt = await peer.command(roomID, 'leave_room', {}, leaveID);
  await rejected(peer.snapshot(roomID), 'not_member');
  assert.deepEqual(await peer.command(roomID, 'leave_room', {}, leaveID), receipt);
  assert.deepEqual(Object.keys(receipt).sort(), ['match_id', 'phase', 'request_id', 'revision', 'room_id', 'winner']);
  await peer.command(roomID, 'join_room', { name: 'Rejoined' });
  const beforeReplay = await host.snapshot(roomID);
  assert.deepEqual(await peer.command(roomID, 'leave_room', {}, leaveID), receipt);
  const afterReplay = await peer.snapshot(roomID);
  assert.equal(afterReplay.revision, beforeReplay.revision);
  assert.equal(afterReplay.players.some((player) => player.user_id === peer.userID), true);
});

test('a caller changing nested form data cannot rewrite a pending committed command', { timeout: 60_000 }, async (t) => {
  const proxy = await faultProxy(config.url);
  t.after(() => proxy.close());
  const [host, peer] = await players(t, 2, { transportURL: proxy.url });
  const roomID = await lobby([host, peer]);
  const before = await host.snapshot(roomID);
  const payload = { settings: { max_players: 8 }, expected_revision: before.revision };
  const requestID = randomUUID();
  proxy.dropNextResponse(requestID);
  await assert.rejects(host.command(roomID, 'update_settings', payload, requestID));
  assert.equal(proxy.stats.droppedResponses, 1);
  payload.settings.max_players = 9;
  payload.expected_revision = 999;
  const committed = await peer.snapshot(roomID);
  assert.equal(committed.settings.max_players, 8);
  const receipt = await host.retry(requestID);
  assert.equal(receipt.revision, committed.revision);
  assert.equal((await host.snapshot(roomID)).settings.max_players, 8);
  assert.equal(host.pendingIDs.length, 0);
});

test('actual refused network request remains pending and reconnect resnapshots before retry', { timeout: 60_000 }, async (t) => {
  const proxy = await faultProxy(config.url);
  t.after(() => proxy.close());
  const [host, peer] = await players(t, 2, { transportURL: proxy.url });
  const roomID = await lobby([host, peer]);
  const before = await peer.snapshot(roomID);
  const forwarded = proxy.stats.forwardedCommands;
  await proxy.disconnect();
  const requestID = randomUUID();
  await assert.rejects(host.command(roomID, 'set_ready', { ready: true }, requestID));
  assert.ok(host.pendingIDs.includes(requestID));
  assert.equal(proxy.stats.forwardedCommands, forwarded);
  assert.equal((await peer.snapshot(roomID)).revision, before.revision);
  await peer.command(roomID, 'set_ready', { ready: true });
  await proxy.reconnect();
  const resnapshot = await host.snapshot(roomID);
  assert.equal(resnapshot.revision, before.revision + 1);
  assert.equal(resnapshot.players.find((player) => player.user_id === peer.userID).ready, true);
  const receipt = await host.retry(requestID);
  assert.equal(receipt.revision, resnapshot.revision + 1);
  assert.equal(host.pendingIDs.length, 0);
  assert.deepEqual(await host.command(roomID, 'set_ready', { ready: true }, requestID), receipt);
  assert.equal((await peer.snapshot(roomID)).revision, receipt.revision);
});

test('real Postgres Changes sockets converge and reconnect catches up from authoritative snapshots', { timeout: 75_000 }, async (t) => {
  const [host, peer] = await players(t, 2);
  const roomID = await lobby([host, peer]);
  const [hostWatch, peerWatch] = await Promise.all([host.watch(roomID), peer.watch(roomID)]);
  assert.equal(host.realtimeConnected(), true);
  assert.equal(peer.realtimeConnected(), true);
  const changed = await host.command(roomID, 'set_ready', { ready: true });
  try {
    await eventually(() => [hostWatch, peerWatch].every((watch) =>
      watch.events.some((event) => event.new.revision === changed.revision) &&
      watch.current?.revision === changed.revision), { message: 'Authenticated sockets did not deliver committed WAL revision' });
  } catch (error) {
    t.diagnostic(JSON.stringify({ expectedRevision: changed.revision, clients: [hostWatch, peerWatch].map((watch) => ({ statuses: watch.statuses, systemEvents: watch.systemEvents, events: watch.events.map((event) => event.new.revision), snapshots: watch.snapshots.map((snapshot) => snapshot.revision), errors: watch.errors })) }));
    throw error;
  }
  await peer.disconnectRealtime();
  assert.equal(peer.realtimeConnected(), false);
  const eventsBeforeDisconnect = peerWatch.events.length;
  const missed = await host.command(roomID, 'set_ready', { ready: false });
  await eventually(() => hostWatch.events.some((event) => event.new.revision === missed.revision) && hostWatch.current?.revision === missed.revision);
  assert.equal(peerWatch.events.length, eventsBeforeDisconnect);
  const reconnectWatch = await peer.watch(roomID);
  assert.equal(peer.realtimeConnected(), true);
  assert.equal(reconnectWatch.current.revision, missed.revision);
  assert.ok(reconnectWatch.reconciliations.some((entry) => entry.reason === 'subscribed' && entry.revision === missed.revision));
  const next = await host.command(roomID, 'set_ready', { ready: true });
  await eventually(() => reconnectWatch.events.some((event) => event.new.revision === next.revision) && reconnectWatch.current?.revision === next.revision, { message: 'Reconnected socket did not deliver new WAL commits' });
  assert.deepEqual(publicProjection(await peer.snapshot(roomID)), publicProjection(await host.snapshot(roomID)));
  for (const event of [...hostWatch.events, ...peerWatch.events, ...reconnectWatch.events]) {
    assert.deepEqual(Object.keys(event.new).sort(), ['changed_at', 'revision', 'room_id']);
  }
});

test('a missed last WAL signal is recovered by bounded HTTP reconciliation while socket is disconnected', { timeout: 60_000 }, async (t) => {
  const [host, peer] = await players(t, 2);
  const roomID = await lobby([host, peer]);
  const watch = await peer.watch(roomID);
  assert.ok(watch.current, 'SUBSCRIBED must reconcile an initial authoritative snapshot');
  peer.disconnectRealtimeTransport();
  assert.equal(peer.realtimeConnected(), false);
  const committed = await host.command(roomID, 'set_ready', { ready: true });
  await eventually(() => watch.current?.revision === committed.revision, {
    timeout: 7_000, message: 'Missing last signal stranded the active watch',
  });
  assert.equal(watch.events.some((event) => event.new.revision === committed.revision), false);
  assert.ok(watch.reconciliations.some((entry) => entry.reason === 'reconcile' && entry.revision === committed.revision));
  assert.equal(watch.current.players.find((player) => player.user_id === host.userID).ready, true);
  await watch.close();
  const afterClose = watch.reconciliations.length;
  await host.command(roomID, 'set_ready', { ready: false });
  await new Promise((resolve) => setTimeout(resolve, 3_100));
  assert.equal(watch.reconciliations.length, afterClose, 'Closing a watch must stop reconciliation timers');
});

test('anonymous, outsider and peer privilege checks block snapshots, signals and secret tables', { timeout: 75_000 }, async (t) => {
  const [host, peer, third, outsider] = await players(t, 4);
  const anon = new GameClient(config);
  t.after(() => anon.close());
  const { roomID, matchID } = await playing([host, peer, third]);
  await assert.rejects(anon.snapshot(roomID), (error) => error.code === '42501' || error.message === 'unauthenticated');
  await rejected(outsider.snapshot(roomID), 'not_member');
  await assert.rejects(anon.command(roomID, 'close_room', { match_id: matchID }));
  await rejected(outsider.command(roomID, 'close_room', { match_id: matchID }), 'not_member');
  for (const client of [anon, outsider]) assertInvisible(await client.signals(roomID), 'unauthorized signal rows visible');
  for (const client of [anon, outsider, peer, host]) {
    for (const table of ['rooms', 'players', 'votes', 'command_receipts']) {
      assertInvisible(await client.privateTable(table), `${table} exposed to a Data API caller`);
    }
  }
  const before = await host.snapshot(roomID);
  await rejected(peer.command(roomID, 'close_room', { match_id: matchID }), 'host_required');
  await assert.rejects(peer.command(roomID, 'update_settings', { settings: { max_players: 4 }, expected_revision: before.revision }));
  for (const illicit of [{ host_id: peer.userID }, { spy_id: peer.userID }, { word: 'attacker' }]) {
    await rejected(host.command(roomID, 'open_voting', { match_id: matchID, ...illicit }), 'invalid_payload');
    const write = await peer.privateTable('rooms', illicit);
    assert.ok(write.error, 'private table write unexpectedly accepted');
  }
  assert.deepEqual(await host.snapshot(roomID), before);
  const [memberWatch, outsiderWatch] = await Promise.all([host.watch(roomID), outsider.watch(roomID)]);
  const command = await host.command(roomID, 'open_voting', { match_id: matchID });
  await eventually(() => memberWatch.events.some((event) => event.new.revision === command.revision));
  // Give the already-active outsider subscription time to receive the same WAL
  // change; it must stay silent while the authorized subscriber receives it.
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.equal(outsiderWatch.events.length, 0);
});

test('concurrent ballots finish one match and stale match commands cannot mutate a replay', { timeout: 60_000 }, async (t) => {
  const clients = await players(t, 3);
  const { roomID, matchID } = await playing(clients);
  const snapshots = await Promise.all(clients.map((client) => client.snapshot(roomID)));
  const spy = clients[snapshots.findIndex((snapshot) => snapshot.own_role === 'spy')];
  const civilian = clients.find((client) => client !== spy);
  await clients[0].command(roomID, 'open_voting', { match_id: matchID });
  const beforeVote = await clients[0].snapshot(roomID);
  await rejected(spy.command(roomID, 'vote', { match_id: matchID, target_id: spy.userID }), 'invalid_target');
  assert.deepEqual(await clients[0].snapshot(roomID), beforeVote);
  await Promise.all(clients.map((client) => client.command(roomID, 'vote', {
    match_id: matchID, target_id: client === spy ? civilian.userID : spy.userID,
  })));
  const finished = await clients[0].snapshot(roomID);
  assert.equal(finished.phase, 'finished');
  assert.equal(finished.winner, 'civilians');
  assert.equal(finished.votes.length, 3);
  assert.equal(new Set(finished.votes.map((vote) => vote.voter_id)).size, 3);
  await clients[0].command(roomID, 'return_to_lobby', { match_id: matchID });
  const returned = await clients[0].snapshot(roomID);
  await rejected(clients[1].command(roomID, 'leave_room', { match_id: matchID }), 'stale_match');
  assert.deepEqual(await clients[0].snapshot(roomID), returned);
  await ready(clients, roomID);
  await clients[0].command(roomID, 'start_game');
  const replay = await clients[0].snapshot(roomID);
  assert.notEqual(replay.match_id, matchID);
  for (const [action, payload] of [['leave_room', {}], ['close_room', {}], ['open_voting', {}], ['vote', { target_id: spy.userID }]]) {
    await rejected(clients[0].command(roomID, action, { match_id: matchID, ...payload }), 'stale_match');
  }
  assert.deepEqual(await clients[0].snapshot(roomID), replay);
});

test('leave and close race has one closed outcome with no lost membership update', { timeout: 60_000 }, async (t) => {
  const clients = await players(t, 4);
  const { roomID, matchID } = await playing(clients);
  const results = await Promise.allSettled([
    clients[1].command(roomID, 'leave_room', { match_id: matchID }),
    clients[0].command(roomID, 'close_room', { match_id: matchID }),
  ]);
  assert.equal(results[1].status, 'fulfilled');
  if (results[0].status === 'rejected') assert.ok(['invalid_phase', 'not_member'].includes(results[0].reason.message));
  assert.equal((await clients[0].snapshot(roomID)).phase, 'closed');
  await assert.rejects(clients[1].command(roomID, 'set_ready', { ready: true }));
});

test('first-delivery stale membership, settings and lobby intents are fenced independently of request replay', { timeout: 60_000 }, async (t) => {
  const clients = await players(t, 3);
  const [host, peer] = clients;
  const roomID = await lobby(clients);
  const oldPeer = await peer.snapshot(roomID);
  const oldHost = await host.snapshot(roomID);
  await host.command(roomID, 'update_settings', { settings: { max_players: 5 }, expected_revision: oldHost.revision });
  const changedSettings = await host.snapshot(roomID);
  await rejected(peer.command(roomID, 'set_ready', {
    ready: true, membership_id: oldPeer.own_membership_id, settings_revision: oldPeer.settings_revision,
  }), 'stale_settings');
  assert.deepEqual(await host.snapshot(roomID), changedSettings);

  await peer.command(roomID, 'leave_room');
  await peer.command(roomID, 'join_room', { name: 'New membership' });
  const rejoined = await peer.snapshot(roomID);
  assert.notEqual(rejoined.own_membership_id, oldPeer.own_membership_id);
  await rejected(peer.command(roomID, 'leave_room', { membership_id: oldPeer.own_membership_id }), 'stale_membership');
  assert.deepEqual(await peer.snapshot(roomID), rejoined);

  await ready(clients, roomID);
  await host.command(roomID, 'start_game');
  const active = await host.snapshot(roomID);
  await host.command(roomID, 'open_voting', { match_id: active.match_id });
  await Promise.all(clients.map((client, index) => client.command(roomID, 'vote', {
    match_id: active.match_id, target_id: clients[(index + 1) % clients.length].userID,
  })));
  await host.command(roomID, 'return_to_lobby', { match_id: active.match_id });
  const nextLobby = await host.snapshot(roomID);
  assert.notEqual(nextLobby.lobby_id, oldHost.lobby_id);
  await rejected(host.command(roomID, 'start_game', { lobby_id: oldHost.lobby_id }), 'stale_lobby');
  await rejected(host.command(roomID, 'close_room', { lobby_id: oldHost.lobby_id }), 'stale_lobby');
  assert.deepEqual(await host.snapshot(roomID), nextLobby);
});

test('a locked room does not block the same user in another room; failed commands roll back', { timeout: 60_000 }, async (t) => {
  assert.ok(process.env.DATABASE_URL, 'Local DATABASE_URL is required for the lock/rollback invariant');
  requireLoopback(process.env.DATABASE_URL, 'DATABASE_URL');
  const [host] = await players(t, 1);
  const roomA = await lobby([host]);
  const roomB = await lobby([host]);
  const db = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await db.connect();
  t.after(async () => { await db.query('ROLLBACK'); await db.end(); });
  const before = await host.snapshot(roomA);
  const invalidID = randomUUID();
  await rejected(host.command(roomA, 'start_game', {}, invalidID), 'not_enough_players');
  assert.deepEqual(await host.snapshot(roomA), before);
  const failedReceipt = await db.query('SELECT count(*)::int AS count FROM game_private.command_receipts WHERE request_id = $1', [invalidID]);
  assert.equal(failedReceipt.rows[0].count, 0);
  await db.query('BEGIN');
  await db.query('SELECT id FROM game_private.rooms WHERE id = $1 FOR UPDATE', [roomA]);
  let settledA = false;
  const blockedA = host.command(roomA, 'set_ready', { ready: true }).finally(() => { settledA = true; });
  // Attach a rejection observer immediately while another request is tested.
  blockedA.catch(() => {});
  try {
    await eventually(async () => {
      await db.query('SELECT pg_stat_clear_snapshot()');
      const waiting = await db.query("SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%game_command%') AS waiting");
      return waiting.rows[0].waiting;
    }, { timeout: 4_000, message: 'Expected real RPC to wait on held room row lock' });
    const independentB = await Promise.race([
      host.command(roomB, 'set_ready', { ready: true }),
      new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('Unrelated room blocked by lock')), 4_000); timer.unref(); }),
    ]);
    assert.equal(independentB.room_id, roomB);
    assert.equal(settledA, false, 'locked-room command must still await its row lock');
  } finally {
    await db.query('COMMIT');
  }
  assert.equal((await blockedA).room_id, roomA);
});
