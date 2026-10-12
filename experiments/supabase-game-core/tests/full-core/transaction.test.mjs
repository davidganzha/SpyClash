import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { before, after } from 'node:test';
import postgres from 'postgres';
import { createClient } from '@supabase/supabase-js';
import { config, serviceURL, createActor, intent, accepted, snapshot, act, lobby, ready, playing, commandProxy } from './fixtures.mjs';

const db = postgres(process.env.DATABASE_URL, { max: 12, idle_timeout: 10, connect_timeout: 10 });
const actors = [];
before(async () => { for (let index = 0; index < 9; index += 1) actors.push(await createActor(index)); });
after(async () => { await Promise.all(actors.map(actor => actor.close())); await db.end(); });
const byEmail = email => actors.find(actor => actor.email === email);

test('real Auth gateway, private tables and RLS signals reject anonymous and outsider access', { timeout: 45_000 }, async () => {
  const room = await lobby(actors.slice(0, 3));
  assert.equal((await actors[0].send({ action: 'get_room', room_id: room.id }, { anonymous: true })).status, 401);
  assert.equal((await actors[8].send({ action: 'get_room', room_id: room.id })).status, 403);
  assert.equal((await actors[8].send(intent(actors[8], room, 'pause_game', { player: { email: actors[0].email } }))).status, 403);
  const forged = await fetch(serviceURL, { method: 'POST', headers: { Authorization: 'Bearer definitely-not-a-signed-token', 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'get_room', room_id: room.id }) });
  assert.equal(forged.status, 401);
  for (const actor of [actors[0], actors[8]]) {
    for (const table of ['rooms', 'receipts', 'history', 'outbox']) {
      const result = await actor.sdk.schema('full_game_private').from(table).select('*').limit(1);
      assert.ok(result.error || result.data?.length === 0, `Direct private ${table} read must be denied`);
    }
  }
  const ownSignals = await actors[0].sdk.from('full_game_room_signals').select('*').eq('room_id', room.id);
  assert.equal(ownSignals.error, null); assert.equal(ownSignals.data.length, 1);
  assert.deepEqual(Object.keys(ownSignals.data[0]).sort(), ['revision', 'room_id', 'updated_at']);
  const outsiderSignals = await actors[8].sdk.from('full_game_room_signals').select('*').eq('room_id', room.id);
  assert.equal(outsiderSignals.error, null); assert.deepEqual(outsiderSignals.data, []);
  const anon = createClient(config.url, config.anonKey, { auth: { persistSession: false } });
  const anonSignals = await anon.from('full_game_room_signals').select('*').eq('room_id', room.id);
  assert.ok(anonSignals.error || anonSignals.data.length === 0);
});

test('concurrent joins/readiness and repeated immutable intents retain every member', { timeout: 45_000 }, async () => {
  const team = actors.slice(0, 6), room = await lobby(team);
  assert.equal(new Set(room.players.map(player => player.email)).size, 6);
  await act(team[0], room, 'begin_ready_check');
  const own = await snapshot(team[0], room), body = intent(team[0], own, 'toggle_ready');
  const same = await Promise.all(Array.from({ length: 12 }, () => accepted(team[0], body)));
  same.forEach(result => assert.deepEqual(result, same[0]));
  await Promise.all(team.slice(1).map(actor => act(actor, room, 'toggle_ready')));
  const current = await snapshot(team[0], room);
  assert.equal(current.ready_players.length, 6);
  assert.equal(current.room_revision, own.room_revision + 6);
  const armBody = intent(team[0], current, 'arm_roulette');
  const armed = await Promise.all(Array.from({ length: 8 }, () => accepted(team[0], armBody)));
  armed.forEach(result => assert.deepEqual(result, armed[0]));
  const [raw] = await db`select state from full_game_private.rooms where id=${room.id}`;
  assert.equal(raw.state.spy_emails.length, 1);
  assert.equal(raw.state.room_revision, current.room_revision + 1);
});

test('lost acknowledgement after commit replays original response after another writer and real offline transport', { timeout: 45_000 }, async t => {
  const team = actors.slice(0, 3), room = await lobby(team);
  await act(team[0], room, 'begin_ready_check');
  const own = await snapshot(team[0], room), body = intent(team[0], own, 'toggle_ready');
  const proxy = await commandProxy(); t.after(() => proxy.close());
  proxy.drop(body.request_id);
  await assert.rejects(team[0].send(body, { url: proxy.url }));
  assert.equal(proxy.stats.dropped, 1); assert.equal(proxy.stats.committedStatus, 200);
  const committed = await snapshot(team[1], room);
  assert.ok(committed.ready_players.includes(team[0].email));
  const changed = (await act(team[1], room, 'toggle_ready')).room;
  const receipt = await accepted(team[0], body, { url: proxy.url });
  assert.equal(receipt.revision, committed.room_revision);
  assert.equal((await snapshot(team[0], room)).room_revision, changed.room_revision);
  assert.equal((await team[0].send({ ...body, action: 'return_to_waiting' })).body.code, 'request_id_reused');
  const third = await snapshot(team[2], room), pending = intent(team[2], third, 'toggle_ready');
  await proxy.disconnect();
  await assert.rejects(team[2].send(pending, { url: proxy.url }));
  assert.equal((await db`select 1 from full_game_private.receipts where actor_id=${team[2].id} and request_id=${pending.request_id}`).length, 0);
  await proxy.reconnect();
  const recovered = await accepted(team[2], pending, { url: proxy.url });
  assert.equal(recovered.room.ready_players.length, 3);
  assert.deepEqual(await accepted(team[2], pending), recovered);
});

test('unrelated room proceeds while another room row is held by a real transaction', { timeout: 30_000 }, async () => {
  const first = await lobby(actors.slice(0, 3)), second = await lobby(actors.slice(0, 3));
  let release, locked;
  const gate = new Promise(resolve => { release = resolve; });
  const acquired = new Promise(resolve => { locked = resolve; });
  const lock = db.begin(async tx => { await tx`select id from full_game_private.rooms where id=${first.id} for update`; locked(); await gate; });
  await acquired;
  let blockedCompleted = false;
  const blocked = accepted(actors[0], intent(actors[0], first, 'update_game_duration', { game_duration_seconds: 240 })).then(result => { blockedCompleted = true; return result; });
  try {
    const independent = await Promise.race([
      accepted(actors[0], intent(actors[0], second, 'update_game_duration', { game_duration_seconds: 300 })),
      new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('Unrelated room command blocked')), 3_000); timer.unref(); }),
    ]);
    assert.equal(independent.room.game_duration_seconds, 300); assert.equal(blockedCompleted, false);
  } finally { release(); await lock; }
  assert.equal((await blocked).room.game_duration_seconds, 240);
});

test('SQL failure rolls back state, signal and receipt; business rejection is a stable failure receipt', { timeout: 30_000 }, async () => {
  const room = await lobby(actors.slice(0, 3)), body = intent(actors[0], room, 'begin_ready_check');
  const name = `test_fault_${randomUUID().replaceAll('-', '')}`;
  assert.match(room.id, /^[0-9a-f-]{36}$/);
  // DDL CHECK expressions cannot retain bind parameters. Only the verified UUID
  // is interpolated as a SQL literal; the generated identifier stays quoted.
  await db`alter table full_game_private.rooms add constraint ${db(name)} check (id <> ${db.unsafe(`'${room.id}'::uuid`)} or state->>'status' <> 'ready_voting') not valid`;
  try {
    assert.equal((await actors[0].send(body)).status, 503);
    assert.equal((await db`select 1 from full_game_private.receipts where actor_id=${actors[0].id} and request_id=${body.request_id}`).length, 0);
    assert.deepEqual(await snapshot(actors[0], room), room);
    const [signal] = await db`select revision from public.full_game_room_signals where room_id=${room.id}`;
    assert.equal(Number(signal.revision), room.room_revision);
  } finally { await db`alter table full_game_private.rooms drop constraint ${db(name)}`; }
  assert.equal((await accepted(actors[0], body)).room.status, 'ready_voting');
  const deniedBody = intent(actors[1], await snapshot(actors[1], room), 'return_to_waiting');
  const denied = await actors[1].send(deniedBody);
  assert.equal(denied.status, 403);
  assert.deepEqual(await actors[1].send(deniedBody), denied);
  assert.equal((await snapshot(actors[0], room)).status, 'ready_voting');
});

test('full questions trace keeps private turn state, server card clock, pause and exactly-once result/replay', { timeout: 60_000 }, async () => {
  const team = actors.slice(0, 3), room = await playing(team);
  let current = await snapshot(team[0], room);
  assert.equal(current.current_answer, '');
  const paused = (await act(team[0], room, 'pause_game')).room;
  assert.ok(paused.game_paused_at);
  const denied = await byEmail(paused.current_asker_email).send(intent(byEmail(paused.current_asker_email), paused, 'advance_question'));
  assert.equal(denied.body.code, 'game_paused');
  await act(team[0], room, 'resume_game');
  for (let turn = 0; turn < 8; turn += 1) {
    current = await snapshot(team[0], room);
    const asker = byEmail(current.current_asker_email);
    if (turn === 0) {
      const first = intent(asker, current, 'advance_question');
      const raced = await Promise.all([asker.send(first), asker.send({ ...first, request_id: randomUUID() })]);
      assert.deepEqual(raced.map(result => result.status).sort(), [200, 409]);
      assert.equal(raced.find(result => result.status === 409).body.code, 'room_revision_conflict');
    } else await act(asker, room, turn % 2 ? 'mark_answer_heard' : 'advance_question');
  }
  current = await snapshot(team[0], room); assert.equal(current.question_phase, 'results');
  current = (await act(team[1], room, 'continue_round')).room;
  assert.equal(current.round_number, 2); assert.equal(current.questions_in_round, 0);
  const views = await Promise.all(team.map(actor => snapshot(actor, room)));
  const spyIndex = views.findIndex((view, index) => view.spy_emails.includes(team[index].email));
  const spy = team[spyIndex], civilianView = views.find(view => view.word !== 'CLASSIFIED');
  assert.ok(spy && civilianView);
  assert.equal(views[spyIndex].word, 'CLASSIFIED');
  const terminalBody = intent(spy, await snapshot(spy, room), 'submit_spy_guess', { guess: civilianView.word });
  const terminals = await Promise.all(Array.from({ length: 6 }, () => accepted(spy, terminalBody)));
  terminals.forEach(result => assert.deepEqual(result, terminals[0]));
  assert.equal(terminals[0].room.winner, 'spy');
  const finishedViews = await Promise.all(team.map(actor => snapshot(actor, room)));
  finishedViews.forEach(view => { assert.equal(view.word, civilianView.word); assert.equal(view.spy_emails.length, 1); });
  assert.equal((await db`select 1 from full_game_private.history where match_id=${current.match_id}`).length, 3);
  assert.equal((await db`select 1 from full_game_private.outbox where room_id=${room.id} and event->>'type'='game_finished'`).length, 1);
  await Promise.all(team.map(actor => act(actor, room, 'vote_play_again', { expected_match_id: current.match_id })));
  const replay = await snapshot(team[0], room);
  assert.equal(replay.status, 'roulette'); assert.equal(replay.replay_source_match_id, current.match_id);
});

test('full associations turn order and N-S voting eject the spy rather than use plurality', { timeout: 60_000 }, async () => {
  const team = actors.slice(0, 3), room = await playing(team, { game_mode: 'associations' });
  await act(team[0], room, 'start_association');
  const speakers = new Set();
  for (let index = 0; index < 3; index += 1) {
    const current = await snapshot(team[0], room); speakers.add(current.current_asker_email);
    await act(byEmail(current.current_asker_email), room, 'stop_association_spin');
    await act(byEmail(current.current_asker_email), room, 'advance_association');
  }
  assert.equal(speakers.size, 3); assert.equal((await snapshot(team[0], room)).round_number, 2);
  await Promise.all(team.slice(0, 2).map(actor => act(actor, room, 'request_vote')));
  const views = await Promise.all(team.map(actor => snapshot(actor, room)));
  const spy = team.find((actor, index) => views[index].spy_emails.includes(actor.email));
  let voting = await snapshot(team[0], room); assert.ok(voting.detective_vote_round_id);
  const selfVote = await spy.send(intent(spy, await snapshot(spy, room), 'cast_detective_vote', { target_email: spy.email, expected_detective_vote_round_id: voting.detective_vote_round_id }));
  assert.equal(selfVote.status, 400);
  const cancelledRound = voting.detective_vote_round_id;
  for (let index = 0; index < team.length; index += 1) {
    await act(team[index], room, 'cast_detective_vote', { target_email: team[(index + 1) % team.length].email, expected_detective_vote_round_id: cancelledRound });
  }
  const cancelled = await snapshot(team[0], room);
  assert.equal(cancelled.status, 'playing'); assert.equal(cancelled.detective_vote_round_id, '');
  assert.equal(cancelled.detective_vote_cancellation_reason, 'no_viable_candidate');
  assert.ok(cancelled.detective_vote_cancellation_event_id); assert.equal(cancelled.detective_vote_cancellation_round_id, cancelledRound);
  await Promise.all(team.slice(0, 2).map(actor => act(actor, room, 'request_vote')));
  voting = await snapshot(team[0], room); assert.notEqual(voting.detective_vote_round_id, cancelledRound);
  const oldBallot = await team[0].send(intent(team[0], voting, 'cast_detective_vote', { target_email: team[1].email, expected_detective_vote_round_id: cancelledRound }));
  assert.equal(oldBallot.status, 409);
  for (const actor of team.filter(actor => actor !== spy)) {
    await act(actor, room, 'cast_detective_vote', { target_email: spy.email, expected_detective_vote_round_id: voting.detective_vote_round_id });
  }
  const ended = await snapshot(team[0], room);
  assert.equal(ended.status, 'finished'); assert.equal(ended.winner, 'detectives');
  assert.equal(ended.detective_votes.length, 2, 'N-S threshold finalizes before every player votes');
});

test('multi-spy projection, stale membership and stale match intents preserve current authority', { timeout: 60_000 }, async () => {
  const team = actors.slice(0, 6), room = await playing(team, { lobby_spy_count: 2, spies_know_each_other: false });
  const views = await Promise.all(team.map(actor => snapshot(actor, room)));
  let spies = 0;
  for (let index = 0; index < team.length; index += 1) {
    const view = views[index], ownSpy = view.spy_emails.includes(team[index].email);
    if (ownSpy) { spies += 1; assert.deepEqual(view.spy_emails, [team[index].email]); assert.equal(view.word, 'CLASSIFIED'); }
    else assert.deepEqual(view.spy_emails, []);
    assert.equal(view.lobby_word_pool.length, 0);
    for (const key of ['terminal_intent', 'departed_player_emails', 'participant_user_ids', 'writer_token']) assert.equal(Object.hasOwn(view, key), false);
  }
  assert.equal(spies, 2);
  const oldLeave = intent(team[1], views[1], 'leave_room');
  await act(team[0], room, 'vote_return_to_lobby', { return_to_lobby_vote: true });
  const staleMatch = await team[1].send(oldLeave);
  assert.equal(staleMatch.status, 409);
  const own = await snapshot(team[1], room), leave = intent(team[1], own, 'leave_room');
  const departed = await accepted(team[1], leave);
  await accepted(team[1], { action: 'join_room', request_id: randomUUID(), room_code: room.code, join_membership_id: randomUUID(), client_capabilities: ['multi_spy_v1'] });
  const rejoined = await snapshot(team[1], room); assert.notEqual(rejoined.viewer_membership_id, own.viewer_membership_id);
  assert.deepEqual(await accepted(team[1], leave), departed);
  assert.equal((await snapshot(team[1], room)).viewer_membership_id, rejoined.viewer_membership_id);
  const lateFirstSend = await team[1].send({ ...leave, request_id: randomUUID() });
  assert.equal(lateFirstSend.status, 409);
  assert.equal((await snapshot(team[1], room)).viewer_membership_id, rejoined.viewer_membership_id);
});

test('lobby mode/duration revisions, target membership kick and host lobby exit keep original rules', { timeout: 30_000 }, async () => {
  const team = actors.slice(0, 4), room = await lobby(team);
  const delayedReady = intent(team[0], room, 'begin_ready_check');
  let current = (await act(team[0], room, 'update_game_mode', { mode: 'associations' })).room;
  current = (await act(team[0], room, 'update_game_duration', { game_duration_seconds: 60 })).room;
  const keys = ['game_mode', 'game_duration_seconds', 'lobby_spy_count', 'spies_know_each_other', 'lobby_word_source', 'lobby_source_pack_id', 'lobby_source_name', 'lobby_theme', 'lobby_category', 'lobby_word_count', 'lobby_word_count_mode', 'lobby_word_pool'];
  const state = Object.fromEntries(keys.map(key => [key, current[key]]));
  state.game_duration_seconds = 120;
  current = (await accepted(team[0], intent(team[0], current, 'update_lobby_state', { mutation_id: randomUUID(), expected_revision: current.lobby_revision, state }))).room;
  assert.equal((await team[0].send(delayedReady)).body.code, 'lobby_revision_conflict');
  const target = current.players.find(player => player.user_id === team[3].id);
  assert.ok(target.membership_id);
  current = (await act(team[0], room, 'kick_player', { target_user_id: team[3].id, expected_target_membership_id: target.membership_id })).room;
  assert.equal(current.players.length, 3);
  assert.equal((await team[3].send({ action: 'get_room', room_id: room.id })).status, 403);
  await act(team[0], room, 'begin_ready_check');
  const notHost = await team[1].send(intent(team[1], await snapshot(team[1], room), 'return_to_waiting'));
  assert.equal(notHost.status, 403);
  current = (await act(team[0], room, 'return_to_waiting')).room;
  assert.equal(current.status, 'waiting'); assert.deepEqual(current.ready_players, []);
  const active = await accepted(team[1], { action: 'get_active_room', preferred_room_id: room.id });
  assert.equal(active.room.id, room.id);
  await act(team[0], room, 'leave_room');
  const [closed] = await db`select closed,state from full_game_private.rooms where id=${room.id}`;
  assert.equal(closed.closed, true); assert.equal(closed.state.status, 'ended');
  assert.equal((await db`select 1 from full_game_private.outbox where room_id=${room.id} and event->>'type'='room_closed'`).length, 1);
});

test('server deadline owns winner and concurrent finalization records one result before host return/close', { timeout: 60_000 }, async () => {
  const team = actors.slice(0, 3), room = await playing(team, { game_duration_seconds: 60 });
  // Deterministic clock fixture only: gameplay actions still use authenticated
  // HTTP. A backdated server timer avoids a one-minute wall-clock test wait.
  await db`update full_game_private.rooms set state=jsonb_set(state,'{game_started_at}',to_jsonb(to_char(clock_timestamp()-interval '90 seconds','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))) where id=${room.id}`;
  const current = await snapshot(team[0], room);
  const bodies = team.map(actor => intent(actor, current, 'finalize_expired_room', { expected_game_started_at: current.game_started_at, winner: 'detectives' }));
  const results = await Promise.all(bodies.map((body, index) => accepted(team[index], body)));
  results.forEach(result => { assert.equal(result.room.status, 'finished'); assert.equal(result.room.winner, 'spy'); });
  assert.equal((await db`select 1 from full_game_private.history where match_id=${current.match_id}`).length, 3);
  assert.equal((await db`select 1 from full_game_private.outbox where room_id=${room.id} and event->>'type'='game_finished'`).length, 1);
  const incomplete = await team[0].send(intent(team[0], results[0].room, 'reset_room_for_replay'));
  assert.equal(incomplete.status, 409); assert.equal(incomplete.body.code, 'replay_votes_incomplete');
  const returned = (await act(team[0], room, 'return_finished_room_to_lobby')).room;
  assert.equal(returned.status, 'waiting'); assert.ok(!returned.match_id);
  await act(team[0], room, 'close_room');
  const [closed] = await db`select closed from full_game_private.rooms where id=${room.id}`; assert.equal(closed.closed, true);
});

test('nine-player three-spy team visibility and wrong guess preserve unranked terminal history', { timeout: 60_000 }, async () => {
  const room = await playing(actors, { lobby_spy_count: 3, spies_know_each_other: true });
  const views = await Promise.all(actors.map(actor => snapshot(actor, room)));
  const spyActors = actors.filter((actor, index) => views[index].spy_emails.includes(actor.email));
  assert.equal(spyActors.length, 3);
  const expectedTeam = spyActors.map(actor => actor.email).sort();
  views.forEach((view, index) => {
    if (spyActors.includes(actors[index])) { assert.deepEqual([...view.spy_emails].sort(), expectedTeam); assert.equal(view.word, 'CLASSIFIED'); }
    else assert.deepEqual(view.spy_emails, []);
    assert.equal(view.exclusion_vote_threshold, 6);
  });
  const finished = (await act(spyActors[0], room, 'submit_spy_guess', { guess: 'Definitely not a configured word' })).room;
  assert.equal(finished.winner, 'detectives'); assert.equal(finished.spy_emails.length, 3);
  const history = await db`select result from full_game_private.history where match_id=${room.match_id}`;
  assert.equal(history.length, 9); history.forEach(entry => assert.equal(entry.result.ranked, false));
  const personal = await accepted(actors[0], { action: 'get_history' });
  assert.equal(personal.history.filter(entry => entry.match_id === room.match_id).length, 1);
});

test('departure before final card acknowledgement abandons armed game instead of starting a partial timer', { timeout: 45_000 }, async () => {
  const team = actors.slice(0, 3), room = await lobby(team);
  const armed = (await act(team[0], room, 'arm_roulette')).room;
  const remaining = Date.parse(armed.intro_started_at) + 3_000 - Date.now();
  if (remaining > 0) await new Promise(resolve => setTimeout(resolve, remaining + 40));
  await act(team[1], room, 'complete_game_start');
  await act(team[0], room, 'mark_role_card_read');
  await act(team[1], room, 'leave_room');
  const waiting = await snapshot(team[0], room);
  assert.equal(waiting.status, 'waiting'); assert.ok(!waiting.game_started_at); assert.ok(!waiting.match_id);
  assert.equal(waiting.players.length, 2);
  assert.equal((await db`select 1 from full_game_private.history where room_id=${room.id}`).length, 0);
});

test('live host departure transfers authority, revokes reads/signals and preserves the original exit receipt', { timeout: 45_000 }, async () => {
  const team = actors.slice(0, 6), room = await playing(team, { lobby_spy_count: 2 });
  const body = intent(team[0], room, 'leave_room');
  const left = await accepted(team[0], body);
  assert.equal(left.room, null);
  const remaining = await snapshot(team[1], room);
  assert.notEqual(remaining.host_email, team[0].email); assert.equal(remaining.status, 'playing');
  assert.equal((await team[0].send({ action: 'get_room', room_id: room.id })).status, 403);
  const active = await accepted(team[0], { action: 'get_active_room', preferred_room_id: room.id });
  assert.notEqual(active.room?.id, room.id);
  const signals = await team[0].sdk.from('full_game_room_signals').select('*').eq('room_id', room.id);
  assert.equal(signals.error, null); assert.deepEqual(signals.data, []);
  assert.deepEqual(await accepted(team[0], body), left);
  const [stored] = await db`select state from full_game_private.rooms where id=${room.id}`;
  assert.ok(stored.state.departed_player_emails.includes(team[0].email));
  assert.ok(stored.state.players.some(player => player.user_id === team[0].id));
  assert.equal((await db`select 1 from full_game_private.members where room_id=${room.id} and user_id=${team[0].id}`).length, 0);
});

test('actual WAL signals arrive and real socket reconnect recovers a missed revision', { timeout: 45_000 }, async t => {
  const room = await lobby(actors.slice(0, 3)), sdk = actors[0].sdk, revisions = [];
  const subscribe = async () => {
    let subscribed;
    const readySignal = new Promise(resolve => { subscribed = resolve; });
    const channel = sdk.channel(`full-core-${randomUUID()}`, { config: { postgres_changes_options: { wait: true, timeout: 15_000 } } })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'full_game_room_signals', filter: `room_id=eq.${room.id}` }, payload => {
        assert.deepEqual(Object.keys(payload.new).sort(), ['revision', 'room_id', 'updated_at']); revisions.push(Number(payload.new.revision));
      }).subscribe(status => { if (status === 'SUBSCRIBED') subscribed(); });
    t.after(() => sdk.removeChannel(channel));
    await Promise.race([readySignal, new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('Realtime never became ready')), 20_000); timer.unref(); })]);
    return channel;
  };
  const expectSignal = async revision => {
    const deadline = Date.now() + 8_000;
    while (!revisions.includes(revision) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 30));
    assert.ok(revisions.includes(revision), 'Actual WAL event required; no snapshot fallback substitutes');
  };
  const channel = await subscribe();
  const updated = (await act(actors[0], room, 'update_game_duration', { game_duration_seconds: 180 })).room;
  await expectSignal(updated.room_revision);
  await sdk.removeChannel(channel); await sdk.realtime.disconnect();
  const missed = (await act(actors[0], room, 'update_game_duration', { game_duration_seconds: 240 })).room;
  assert.equal(revisions.includes(missed.room_revision), false);
  sdk.realtime.connect();
  await subscribe();
  const recovered = await snapshot(actors[0], room);
  assert.equal(recovered.room_revision, missed.room_revision); assert.equal(recovered.game_duration_seconds, 240);
  const subsequent = (await act(actors[0], room, 'update_game_duration', { game_duration_seconds: 300 })).room;
  await expectSignal(subsequent.room_revision);
});
