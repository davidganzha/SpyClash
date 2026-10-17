import assert from 'node:assert/strict';
import test, {before, after} from 'node:test';
import postgres from 'postgres';
import {createClient} from '@supabase/supabase-js';
import {executeApp} from '../../supabase/functions/app-services/dispatcher.ts';
import {executeGame} from '../../supabase/functions/full-game-core/service.ts';
import {processAccountDeletionJobs} from '../../supabase/functions/app-services/lifecycle.ts';

let db;
const users = [];
const endpoint = process.env.APP_SERVICES_URL;
before(() => {
  for (const [value, port] of [[endpoint, '56326'], [process.env.SUPABASE_URL, '56321'], [process.env.DATABASE_URL, '56322']]) {
    const url = new URL(value);
    assert.equal(url.hostname, '127.0.0.1');
    assert.equal(url.port, port);
  }
  db = postgres(process.env.DATABASE_URL, {max: 4, onnotice: () => {}});
});
const command = (action, fields = {}) => ({service: 'community', action, ...fields, request_id: crypto.randomUUID()});
async function call(user, body) {
  const response = await fetch(endpoint, {
    method: 'POST', headers: {Authorization: 'Bearer ' + user.token, 'Content-Type': 'application/json'},
    body: JSON.stringify(body),
  });
  const result = await response.json();
  assert.equal(response.status, 200, result.code || 'application command must succeed');
  return result;
}
async function account() {
  const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, {
    auth: {persistSession: false, autoRefreshToken: false, detectSessionInUrl: false},
  });
  const email = `social-realtime-${crypto.randomUUID()}@example.test`;
  const {data, error} = await client.auth.signUp({email, password: 'Local-fixture-' + crypto.randomUUID()});
  assert.ifError(error);
  const user = {id: data.user.id, email: data.user.id + '@example.test', contactEmail: email,
    full_name: 'Realtime fixture', metadata: {}, client, token: data.session.access_token};
  users.push(user);
  await call(user, {service: 'profile', action: 'current'});
  return user;
}
async function watch(user, recipientID = user.id) {
  const events = [];
  const channel = user.client.channel('social-' + crypto.randomUUID());
  for (const table of ['app_user_signals', 'app_profile_signals']) {
    channel.on('postgres_changes', {event: '*', schema: 'public', table, filter: 'recipient_user_id=eq.' + recipientID},
      payload => events.push({table, record: payload.new, at: performance.now()}));
  }
  await new Promise((resolve, reject) => {
    let joined = false, postgresReady = false;
    const ready = () => { if (joined && postgresReady) { clearTimeout(timeout); resolve(); } };
    const timeout = setTimeout(() => reject(new Error('Realtime subscription timed out')), 10000);
    channel.on('system', {}, payload => {
      if (payload.extension === 'postgres_changes' && payload.status === 'ok') { postgresReady = true; ready(); }
      else if (payload.status === 'error') { clearTimeout(timeout); reject(new Error('PostgreSQL subscription rejected')); }
    });
    channel.subscribe(status => {
      if (status === 'SUBSCRIBED') { joined = true; ready(); }
      else if (['CHANNEL_ERROR', 'TIMED_OUT', 'CLOSED'].includes(status)) {
        clearTimeout(timeout); reject(new Error('Realtime subscription: ' + status));
      }
    });
  });
  return {events, channel};
}
async function waitForEvent(watch, table, since, predicate = () => true) {
  const deadline = performance.now() + 5000;
  while (performance.now() < deadline) {
    const event = watch.events.find(e => e.table === table && e.at >= since && predicate(e.record));
    if (event) return event;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.fail('No matching committed social event within five seconds');
}
after(async () => {
  for (const user of users) await user.client.removeAllChannels();
  for (const user of users) {
    await executeApp(db, user, {service: 'profile', action: 'delete', request_id: crypto.randomUUID()});
    await db`update app_private.lifecycle_jobs set next_attempt_at=clock_timestamp() where user_id=${user.id}`;
    await processAccountDeletionJobs(db, process.env, fetch, user.id);
  }
  if (db) await db.end();
});

test('social events deliver to two authenticated clients, isolate outsiders, and recover after disconnect', {timeout: 60000}, async t => {
  const host = await account(), guest = await account(), outsider = await account();
  const hostWatch = await watch(host), guestWatch = await watch(guest);
  const forbiddenWatch = await watch(outsider, guest.id);
  const outsiderWatch = await watch(outsider);
  const sentAt = performance.now();
  const request = command('send_request', {target_user_id: guest.id});
  const replies = await Promise.all(Array.from({length: 4}, () => call(host, request)));
  replies.forEach(value => assert.deepEqual(value, replies[0], 'lost-ACK replay returns the original response'));
  const received = await waitForEvent(guestWatch, 'app_user_signals', sentAt);
  assert.equal(received.record.recipient_user_id, guest.id);
  assert.deepEqual(Object.keys(received.record).sort(), ['recipient_user_id', 'revision', 'updated_at']);
  const incoming = await call(guest, {service: 'community', action: 'state'});
  assert.equal(incoming.incoming.length, 1);
  const friendshipID = incoming.incoming[0].id;
  assert.equal((await db`select 1 from app_private.receipts where actor_id=${host.id} and request_id=${request.request_id}`).length, 1);
  t.diagnostic(`Local friend request HTTP start to guest realtime signal: ${(received.at - sentAt).toFixed(1)} ms`);

  const acceptedAt = performance.now();
  await call(guest, command('accept', {friendship_id: friendshipID}));
  await waitForEvent(hostWatch, 'app_user_signals', acceptedAt);
  assert.equal((await call(host, {service: 'community', action: 'state'})).friends.length, 1);
  const renamedAt = performance.now();
  await call(host, {service: 'profile', action: 'update', display_name: 'Fresh realtime name', request_id: crypto.randomUUID()});
  await waitForEvent(guestWatch, 'app_profile_signals', renamedAt, r => r.profile_user_id === host.id);

  const created = await executeGame(db, host, {action: 'create_room', request_id: crypto.randomUUID()});
  assert.equal(created.status, 200);
  const room = created.body.room;
  const inviteAt = performance.now();
  await call(host, command('invite_to_room', {target_user_id: guest.id, room_id: room.id, room_code: room.code}));
  const invited = await waitForEvent(guestWatch, 'app_user_signals', inviteAt);
  const invitedState = await call(guest, {service: 'community', action: 'state'});
  assert.equal(invitedState.incoming_room_invites.length, 1);
  assert.equal(invitedState.incoming_room_invites[0].sender.display_name, 'Fresh realtime name');
  t.diagnostic(`Local room invite HTTP start to guest realtime signal: ${(invited.at - inviteAt).toFixed(1)} ms`);

  await guest.client.removeChannel(guestWatch.channel);
  await call(host, command('remove_friend', {friendship_id: friendshipID}));
  const reconnected = await watch(guest);
  // Signals are invalidations, not a durable event log: refresh after subscription
  // acknowledgement closes the offline gap, as the iOS service's onCatchUp does.
  const recovered = await call(guest, {service: 'community', action: 'state'});
  assert.equal(recovered.friends.length, 0);
  assert.equal(recovered.incoming_room_invites.length, 0);
  const newRequestAt = performance.now();
  await call(host, command('send_request', {target_user_id: guest.id}));
  await waitForEvent(reconnected, 'app_user_signals', newRequestAt);
  assert.equal((await call(guest, {service: 'community', action: 'state'})).incoming.length, 1);

  const outsiderAt = performance.now();
  await call(outsider, {service: 'profile', action: 'update', display_name: 'Outsider connection works', request_id: crypto.randomUUID()});
  await waitForEvent(outsiderWatch, 'app_profile_signals', outsiderAt);
  assert.deepEqual(forbiddenWatch.events, [], 'a working outsider connection must never receive another account signals');
  const forbiddenRead = await outsider.client.from('app_user_signals').select('*').eq('recipient_user_id', guest.id);
  assert.ifError(forbiddenRead.error);
  assert.deepEqual(forbiddenRead.data, []);
});
