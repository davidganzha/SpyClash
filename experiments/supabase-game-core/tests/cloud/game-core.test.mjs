import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import { cloudTestConfig, GameClient, syntheticTestActors, eventually } from '../../client/game-client.mjs';
import { faultProxy } from '../fault-proxy.mjs';

const config = cloudTestConfig();
const actors = syntheticTestActors();
const clients = [];
before(async () => {
  for (const actor of actors.slice(0, 6)) {
    const client = new GameClient(config);
    clients.push(client);
    await client.signIn(actor);
  }
});
after(async () => { await Promise.all(clients.map((client) => client.close())); });

async function lobby(selected = clients) {
  const roomID = randomUUID();
  await selected[0].command(roomID, 'create_room', { name: selected[0].name, settings: { max_players: 12 } });
  await Promise.all(selected.slice(1).map((client) => client.command(roomID, 'join_room', { name: client.name })));
  await Promise.all(selected.map((client) => client.snapshot(roomID)));
  return roomID;
}

test('cloud: six independent Auth sessions serialize joins, readiness, starts and ballots', { timeout: 120_000 }, async () => {
  const roomID = await lobby();
  assert.equal(new Set(clients.map((client) => client.userID)).size, 6);
  const joined = await clients[0].snapshot(roomID);
  assert.equal(joined.players.length, 6);
  await Promise.all(clients.map((client) => client.command(roomID, 'set_ready', { ready: true })));
  const before = await clients[0].snapshot(roomID);
  assert.ok(before.players.every((player) => player.ready));
  const starts = await Promise.allSettled(Array.from({ length: 8 }, () => clients[0].command(roomID, 'start_game')));
  assert.equal(starts.filter((result) => result.status === 'fulfilled').length, 1);
  assert.ok(starts.filter((result) => result.status === 'rejected').every((result) => result.reason.message === 'invalid_phase'));
  const snapshots = await Promise.all(clients.map((client) => client.snapshot(roomID)));
  const matchID = snapshots[0].match_id;
  assert.equal(new Set(snapshots.map((snapshot) => snapshot.match_id)).size, 1);
  assert.equal(snapshots[0].revision, before.revision + 1);
  assert.equal(snapshots.filter((snapshot) => snapshot.own_role === 'spy').length, 1);
  assert.equal(snapshots.find((snapshot) => snapshot.own_role === 'spy').own_word, null);
  for (const snapshot of snapshots) {
    for (const key of ['secret_word', 'spy_id', 'roles']) assert.equal(Object.hasOwn(snapshot, key), false);
  }
  await clients[0].command(roomID, 'open_voting', { match_id: matchID });
  await Promise.all(clients.map((client, index) => client.command(roomID, 'vote', { match_id: matchID, target_id: clients[(index + 1) % 6].userID })));
  const finished = await clients[0].snapshot(roomID);
  assert.equal(finished.phase, 'finished');
  assert.equal(finished.votes.length, 6);
  assert.equal(new Set(finished.votes.map((vote) => vote.voter_id)).size, 6);
  await clients[0].command(roomID, 'close_room', { match_id: matchID });
});

test('cloud: lost HTTPS acknowledgement after COMMIT replays original receipt after a different writer', { timeout: 90_000 }, async (t) => {
  const proxy = await faultProxy(config.url, { config });
  const host = new GameClient(config, { transportURL: proxy.url });
  t.after(async () => { await host.close(); await proxy.close(); });
  await host.signIn(actors[0]);
  const peer = clients[1];
  const roomID = await lobby([host, peer]);
  const before = await host.snapshot(roomID);
  const requestID = randomUUID();
  proxy.dropNextResponse(requestID);
  await assert.rejects(host.command(roomID, 'set_ready', { ready: true }, requestID));
  assert.equal(proxy.stats.droppedResponses, 1);
  assert.ok(host.pendingIDs.includes(requestID));
  assert.equal((await peer.snapshot(roomID)).revision, before.revision + 1);
  await peer.command(roomID, 'set_ready', { ready: true });
  const current = await peer.snapshot(roomID);
  const replay = await host.retry(requestID);
  assert.equal(replay.revision, before.revision + 1);
  assert.equal((await host.snapshot(roomID)).revision, current.revision);
  assert.equal(host.pendingIDs.length, 0);
  await host.command(roomID, 'close_room');
});

test('cloud: refused HTTP connection retains pending command and reconnect preserves its ID', { timeout: 90_000 }, async (t) => {
  const proxy = await faultProxy(config.url, { config });
  const host = new GameClient(config, { transportURL: proxy.url });
  t.after(async () => { await host.close(); await proxy.close(); });
  await host.signIn(actors[0]);
  const peer = clients[1];
  const roomID = await lobby([host, peer]);
  const before = await host.snapshot(roomID);
  const requestID = randomUUID();
  await proxy.disconnect();
  await assert.rejects(host.command(roomID, 'set_ready', { ready: true }, requestID));
  assert.ok(host.pendingIDs.includes(requestID));
  assert.equal((await peer.snapshot(roomID)).revision, before.revision);
  await peer.command(roomID, 'set_ready', { ready: true });
  await proxy.reconnect();
  assert.equal((await host.snapshot(roomID)).revision, before.revision + 1);
  const result = await host.retry(requestID);
  assert.equal(result.request_id, requestID);
  assert.equal(result.revision, before.revision + 2);
  assert.deepEqual(await host.command(roomID, 'set_ready', { ready: true }, requestID), result);
  await host.command(roomID, 'close_room');
});

test('cloud: real WAL events reach six clients and a physically reconnected socket', { timeout: 120_000 }, async (t) => {
  const roomID = await lobby();
  const watches = await Promise.all(clients.map((client) => client.watch(roomID)));
  t.after(async () => { await Promise.all(watches.map((watch) => watch.close())); });
  const committed = await clients[0].command(roomID, 'set_ready', { ready: true });
  await eventually(() => watches.every((watch) => watch.events.some((event) => event.new.revision === committed.revision)), { timeout: 20_000, message: 'Six cloud WAL subscriptions did not all receive the committed revision' });
  const last = clients[5];
  await last.disconnectRealtime();
  assert.equal(last.realtimeConnected(), false);
  const missed = await clients[0].command(roomID, 'set_ready', { ready: false });
  const reconnected = await last.watch(roomID);
  t.after(() => reconnected.close());
  assert.equal(reconnected.current.revision, missed.revision);
  const next = await clients[0].command(roomID, 'set_ready', { ready: true });
  await eventually(() => reconnected.events.some((event) => event.new.revision === next.revision), { timeout: 20_000, message: 'Reconnected cloud socket did not receive actual WAL event' });
  await clients[0].command(roomID, 'close_room');
});
