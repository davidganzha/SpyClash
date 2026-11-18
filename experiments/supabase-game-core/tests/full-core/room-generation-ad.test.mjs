import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createActor, intent, snapshot, act, lobby } from './fixtures.mjs';

test('host and two guests converge through actual WAL signals without guest reward or completion commands', { timeout: 45_000 }, async t => {
  const actors = [];
  for (let i = 0; i < 3; i++) actors.push(await createActor(i));
  t.after(async () => { await Promise.all(actors.map(actor => actor.close())); });
  const room = await lobby(actors), guestRevisions = [[], []];
  for (const [index, guest] of actors.slice(1).entries()) {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Guest realtime subscription did not become ready')), 15_000);
      const channel = guest.sdk.channel(`room-ad-${randomUUID()}`, { config: { postgres_changes_options: { wait: true, timeout: 15_000 } } })
        .on('postgres_changes', { event: '*', schema: 'public', table: 'full_game_room_signals', filter: `room_id=eq.${room.id}` }, event => {
          assert.deepEqual(Object.keys(event.new).sort(), ['revision', 'room_id', 'updated_at']);
          guestRevisions[index].push(Number(event.new.revision));
        }).subscribe(status => { if (status === 'SUBSCRIBED') { clearTimeout(timer); resolve(); } });
      t.after(() => guest.sdk.removeChannel(channel));
    });
  }
  const expectBoth = async revision => {
    const deadline = Date.now() + 8_000;
    while (!guestRevisions.every(list => list.includes(revision)) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
    assert.ok(guestRevisions.every(list => list.includes(revision)), 'Both guests must receive actual room WAL updates');
  };
  const sessionID = randomUUID();
  const begin = (await act(actors[0], room, 'set_generation_ad', { generation_ad_session_id: sessionID, generation_ad_state: 'presenting' })).room;
  await expectBoth(begin.room_revision);
  const guests = await Promise.all(actors.slice(1).map(actor => snapshot(actor, room)));
  for (const guest of guests) {
    assert.equal(guest.room_generation_ad.id, sessionID);
    assert.deepEqual(guest.room_generation_ad, begin.room_generation_ad);
    assert.deepEqual(Object.keys(guest.room_generation_ad).sort(), ['expires_at', 'host_email', 'id', 'started_at']);
  }
  for (const guest of actors.slice(1)) {
    const denied = await guest.send(intent(guest, room, 'set_generation_ad', { generation_ad_session_id: sessionID, generation_ad_state: 'ended' }));
    assert.equal(denied.status, 403); assert.equal(denied.body.code, 'room_ad_host_required');
  }
  // Guest1 declines and guest2 has no available SDK ad: both remain local
  // choices. Neither sends a success receipt or a rewarded-generation request.
  const ended = (await act(actors[0], room, 'set_generation_ad', { generation_ad_session_id: sessionID, generation_ad_state: 'ended' })).room;
  await expectBoth(ended.room_revision);
  for (const actor of actors) assert.equal((await snapshot(actor, room)).room_generation_ad, null);
  assert.equal(ended.status, 'waiting');
  const ready = (await act(actors[0], room, 'begin_ready_check')).room;
  assert.equal(ready.status, 'ready_voting', 'Host proceeds without guest ad acknowledgements');
  await act(actors[0], ready, 'close_room');
});
