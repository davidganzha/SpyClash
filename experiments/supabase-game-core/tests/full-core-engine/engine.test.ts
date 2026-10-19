import assert from "node:assert/strict";
import { reduceGame, projectGame, gameDeadline, type GameRecord, type GameActor, type GameTransition } from "../../supabase/functions/full-game-core/engine.ts";
import { lobbyStateFromRoom } from "../../supabase/functions/full-game-core/rules/lobby-state-policy.ts";

const actors: GameActor[] = Array.from({ length: 13 }, (_, i) => ({ id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`, email: `operative${i + 1}@example.test`, full_name: `Operative ${i + 1}` }));
const caps = ["multi_spy_v1"];
const turnActions = new Set(["advance_question", "advance_association", "start_association", "stop_association_spin", "mark_answer_heard", "continue_round"]);
const exercised = new Set<string>();
function reject(fn: () => unknown, code?: string) {
  assert.throws(fn, (error: unknown) =>
    error instanceof Error && (!code || ("code" in error && error.code === code)), code);
}
class Game {
  room: GameRecord | null = null;
  now = Date.parse("2026-10-12T12:00:00.000Z");
  serial = 100;
  history: GameRecord[] = [];
  events: GameRecord[] = [];
  uuid = () => `00000000-0000-4000-8000-${String(++this.serial).padStart(12, "0")}`;
  send(action: string, who: number | GameActor = 0, payload: GameRecord = {}): GameTransition {
    const actor = typeof who === "number" ? actors[who] : who;
    const player = this.room?.players?.find((p: GameRecord) => p.email === actor.email);
    const fenced: GameRecord = {
      ...(this.room?.match_id ? { expected_match_id: this.room.match_id } : {}),
      ...(player ? { expected_membership_id: player.membership_id } : {}),
      ...(turnActions.has(action) ? { expected_revision: this.room?.room_revision } : {}),
      ...payload,
    };
    const before = JSON.stringify(this.room);
    const output = reduceGame({ room: this.room, actor, action, payload: fenced, now: this.now, random: () => 0.31, uuid: this.uuid, roomID: "10000000-0000-4000-8000-000000000001", roomCode: "ABC234" });
    assert.equal(JSON.stringify(this.room), before, "reducer mutated its input");
    output.room.room_revision = Number(this.room?.room_revision || 0) + 1;
    this.room = output.room; this.history.push(...output.history || []); this.events.push(...output.events || []); exercised.add(action); return output;
  }
  actor(email: string) { return actors.find((a) => a.email === email)!; }
  lobby(count = 3, mode = "questions", spies = 1, know = false) {
    this.send("create_room", 0, { player: { name: "Host", client_capabilities: caps } });
    for (let i = 1; i < count; i++) this.send("join_room", i, { player: { name: `Operative ${i}`, client_capabilities: caps } });
    this.send("update_lobby_state", 0, { mutation_id: this.uuid(), expected_revision: this.room!.lobby_revision, state: { game_mode: mode, game_duration_seconds: 60, lobby_spy_count: spies, spies_know_each_other: know, lobby_word_source: "manual", lobby_source_pack_id: "", lobby_source_name: "Test source", lobby_theme: "", lobby_category: "Places", lobby_word_count: 3, lobby_word_count_mode: "custom", lobby_word_pool: ["Museum", "Station", "Airport"].map((word, i) => ({ id: `word${i}`, word, enabled: true })) } });
    return this;
  }
  start() {
    this.send("arm_roulette", this.actor(this.room!.host_email), { expected_lobby_revision: this.room!.lobby_revision, plan: { spy_email: "attacker", secret_word: "Injected", word: "Injected" } });
    this.now += 3001; this.send("complete_game_start", 1);
    for (const player of [...this.room!.players]) this.send("mark_role_card_read", this.actor(player.email));
    assert.ok(this.room!.game_started_at); return this;
  }
  voteOpen() {
    const active = this.room!.players.filter((p: GameRecord) => !this.room!.spectators.includes(p.email));
    for (const p of active.slice(0, Math.ceil(active.length * .51))) this.send("request_vote", this.actor(p.email));
    assert.ok(this.room!.detective_vote_round_id); return this.room!.detective_vote_round_id;
  }
  vote(who: GameActor, target: string, round = this.room!.detective_vote_round_id) { return this.send("cast_detective_vote", who, { target_email: target, expected_vote_round_id: round }); }
}

Deno.test("lobby contract, host settings, capacity, readiness, server-owned secrets and intro", () => {
  const g = new Game().lobby();
  assert.equal(g.room!.code, "ABC234"); assert.equal(g.room!.lobby_revision, 1);
  g.send("get_room", 1); g.send("get_active_room", 1);
  reject(() => g.send("update_game_mode", 1, { mode: "associations" }));
  g.send("update_game_mode", 0, { mode: "associations" });
  g.send("update_game_duration", 0, { game_duration_seconds: 90 });
  g.send("update_game_mode", 0, { mode: "questions" });
  g.send("begin_ready_check"); g.send("toggle_ready", 0);
  reject(() => g.send("arm_roulette", 0, { expected_lobby_revision: g.room!.lobby_revision }));
  g.send("return_to_waiting"); assert.deepEqual(g.room!.ready_players, []);
  g.send("begin_ready_check"); actors.slice(0, 3).forEach((a) => g.send("toggle_ready", a));
  g.send("arm_roulette", 0, { expected_lobby_revision: g.room!.lobby_revision, plan: { secret_word: "Injected", spy_email: "attacker" } });
  assert.ok(["Museum", "Station", "Airport"].includes(g.room!.word)); assert.notEqual(g.room!.spy_email, "attacker");
  const frozen = [g.room!.word, g.room!.spy_email, g.room!.roulette_target_email];
  g.send("arm_roulette", 0); assert.deepEqual([g.room!.word, g.room!.spy_email, g.room!.roulette_target_email], frozen);
  reject(() => g.send("complete_game_start", 1)); g.now += 3001; g.send("complete_game_start", 1);
  assert.equal(g.room!.game_started_at, null);
  g.send("mark_role_card_read", 0); g.send("mark_role_card_read", 1); assert.equal(g.room!.game_started_at, null);
  g.send("mark_role_card_read", 2); assert.equal(g.room!.game_started_at, new Date(g.now).toISOString());
  assert.equal(g.events.filter((e) => e.type === "game_started").length, 1);
  g.send("complete_game_start", 2); assert.equal(g.events.length, 1);
  const full = new Game().lobby(12); reject(() => full.send("join_room", 12, { client_capabilities: caps }), "room_full");
});

Deno.test("projection preserves multi-spy teammate policy and never exposes secret to active spy", () => {
  for (const know of [false, true]) {
    const g = new Game().lobby(6, "questions", 2, know).start();
    assert.equal(g.room!.spy_emails.length, 2);
    for (const actor of actors.slice(0, 6)) {
      const view = projectGame(g.room!, actor), isSpy = g.room!.spy_emails.includes(actor.email);
      assert.equal(view.viewer_membership_id, g.room!.players.find((p: GameRecord) => p.email === actor.email).membership_id);
      if (isSpy) { assert.equal(view.word, "CLASSIFIED"); assert.equal(view.secret_word, "CLASSIFIED"); assert.equal(view.spy_emails.length, know ? 2 : 1); }
      else { assert.equal(view.word, g.room!.word); assert.deepEqual(view.spy_emails, []); }
      assert.deepEqual(view.lobby_word_pool, []); assert.equal(view.word_pool.length, 3);
    }
    reject(() => projectGame(g.room!, actors[9]), "room_access_revoked");
  }
});

Deno.test("host transfer preserves the roster and settings, resets readiness and changes authority", () => {
  const g = new Game().lobby(4);
  g.send("begin_ready_check");
  g.send("toggle_ready", 1);
  const prior = structuredClone(g.room!);
  const target = prior.players[1];
  const payload = {
    target_user_id: target.user_id,
    target_email: target.email,
    expected_target_membership_id: target.membership_id,
    expected_revision: prior.room_revision,
  };
  reject(() => g.send("transfer_host", 2, payload), "transfer_host_required");
  g.send("transfer_host", 0, payload);
  assert.equal(g.room!.host_email, actors[1].email);
  assert.equal(g.room!.status, "waiting");
  assert.deepEqual(g.room!.ready_players, []);
  assert.deepEqual(g.room!.players, prior.players);
  assert.deepEqual(lobbyStateFromRoom(g.room!), lobbyStateFromRoom(prior));
  assert.equal(g.room!.lobby_revision, prior.lobby_revision);
  assert.equal(g.room!.room_revision, prior.room_revision + 1);
  reject(() => g.send("transfer_host", 0, payload), "transfer_host_required");
  reject(() => g.send("update_game_duration", 0, { game_duration_seconds: 120 }));
  g.send("update_game_duration", 1, { game_duration_seconds: 120 });
  assert.equal(g.room!.game_duration_seconds, 120);
  g.send("leave_room", 0);
  assert.equal(g.room!.closed, false, "The former host leaves as a regular member");
  assert.equal(g.room!.host_email, actors[1].email);
  assert.equal(g.room!.players.length, 3);
  g.send("close_room", 1);
  assert.equal(g.room!.closed, true, "Only the new host owns the lobby close action");
});

Deno.test("host transfer rejects changed roster generation, room revision and active play", () => {
  const g = new Game().lobby(4);
  const target = g.room!.players[1];
  const payload = {
    target_user_id: target.user_id,
    target_email: target.email,
    expected_target_membership_id: target.membership_id,
    expected_revision: g.room!.room_revision,
  };
  reject(() => g.send("transfer_host", 0, { ...payload, target_email: actors[2].email }));
  reject(() => g.send("transfer_host", 0, { ...payload, expected_target_membership_id: "old-membership" }));
  reject(() => g.send("transfer_host", 0, { ...payload, expected_revision: g.room!.room_revision - 1 }));
  reject(() => g.send("transfer_host", 0, { ...payload, target_user_id: actors[0].id, target_email: actors[0].email }));
  const original = structuredClone(g.room!);
  const reusedID = structuredClone(target);
  reusedID.email = actors[2].email;
  g.room!.players.push(reusedID);
  reject(() => g.send("transfer_host", 0, payload));
  g.room = original;
  g.start();
  reject(() => g.send("transfer_host", 0, { ...payload, expected_revision: g.room!.room_revision }));
  assert.equal(g.room!.host_email, actors[0].email);
});

Deno.test("question turns cycle, results after eight, next round and stale turn fence", () => {
  const g = new Game().lobby(4).start();
  const seen: string[] = [];
  for (let i = 0; i < 8; i++) {
    const revision = g.room!.room_revision, asker = g.actor(g.room!.current_asker_email);
    seen.push(asker.email); g.send(i % 2 ? "mark_answer_heard" : "advance_question", asker);
    reject(() => g.send("advance_question", asker, { expected_revision: revision }), "room_revision_conflict");
  }
  assert.equal(g.room!.question_phase, "results"); assert.equal(g.room!.questions_in_round, 7);
  assert.equal(new Set(seen.slice(0, 4)).size, 4);
  g.send("continue_round", 0); assert.equal(g.room!.round_number, 2); assert.equal(g.room!.questions_in_round, 0);
});

Deno.test("association order and round, settled spin, wrong mode/actor rejected", () => {
  const g = new Game().lobby(4, "associations").start();
  g.send("start_association", 0);
  const speakers = new Set<string>();
  for (let i = 0; i < 4; i++) {
    const speaker = g.actor(g.room!.current_asker_email); speakers.add(speaker.email);
    g.send("stop_association_spin", 1); assert.equal(JSON.parse(g.room!.current_answer).spinning, false);
    reject(() => g.send("advance_association", actors.slice(0, 4).find((a) => a.email !== speaker.email)!));
    g.send("advance_association", speaker);
  }
  assert.equal(speakers.size, 4); assert.equal(g.room!.round_number, 2);
  reject(() => g.send("advance_question", g.actor(g.room!.current_asker_email)));
});

Deno.test("strict majority opens vote, N-S ejects spy, immutable vote and atomic terminal output", () => {
  const g = new Game().lobby(4).start();
  g.send("request_vote", 0); g.send("request_vote", 1); assert.equal(g.room!.detective_vote_round_id, "");
  g.send("request_vote", 2); const round = g.room!.detective_vote_round_id; assert.ok(round);
  const spy = g.actor(g.room!.spy_email), detectives = actors.slice(0, 4).filter((a) => a.email !== spy.email);
  reject(() => g.vote(spy, spy.email));
  g.vote(detectives[0], spy.email);
  const count = g.room!.detective_votes.length; g.vote(detectives[0], spy.email); assert.equal(g.room!.detective_votes.length, count);
  reject(() => g.vote(detectives[0], detectives[1].email));
  g.vote(detectives[1], spy.email); assert.equal(g.room!.status, "playing");
  const end = g.vote(detectives[2], spy.email);
  assert.equal(g.room!.winner, "detectives"); assert.equal(g.room!.status, "finished");
  assert.equal(end.history!.length, 4); assert.equal(new Set(end.history!.map((h) => h.result_key)).size, 4);
  assert.equal(end.events!.filter((e) => e.type === "game_finished").length, 1);
  assert.ok(g.room!.terminal_intent.game_finished_outbox_commit);
  assert.equal(projectGame(g.room!, spy).word, g.room!.word);
});

Deno.test("split vote cancels with stable event and later round rejects old votes", () => {
  const g = new Game().lobby(4).start(); const old = g.voteOpen();
  g.vote(actors[0], actors[1].email); g.vote(actors[1], actors[0].email); g.vote(actors[2], actors[3].email);
  assert.equal(g.room!.detective_vote_round_id, ""); assert.ok(g.room!.detective_vote_cancellation_event_id);
  assert.ok(Date.parse(g.room!.detective_vote_cancellation_present_at) > g.now);
  const next = g.voteOpen(); assert.notEqual(next, old);
  reject(() => g.vote(actors[0], actors[1].email, old));
});

Deno.test("multi-spy N-S nonterminal ejection keeps eliminated spectator and rotation valid", () => {
  const g = new Game().lobby(6, "associations", 2).start(); g.send("start_association");
  const spy = g.room!.spy_emails[0], voters = actors.slice(0, 6).filter((a) => a.email !== spy);
  g.voteOpen(); voters.slice(0, 4).forEach((a) => g.vote(a, spy));
  assert.equal(g.room!.status, "playing"); assert.ok(g.room!.spectators.includes(spy));
  reject(() => g.send("advance_association", g.actor(spy))); reject(() => g.send("submit_spy_guess", g.actor(spy), { guess: g.room!.word }));
  g.send("join_room", g.actor(spy), { client_capabilities: caps }); assert.ok(g.room!.spectators.includes(spy), "rejoin must not undo ejection");
  assert.notEqual(g.room!.current_asker_email, spy);
});

Deno.test("pause/resume excludes suspended time and timer has precise server boundary", () => {
  const g = new Game().lobby().start(); const start = g.now;
  g.now += 10_000; g.send("pause_game"); assert.equal(gameDeadline(g.room!), null);
  reject(() => g.send("request_vote", 1), "game_paused"); reject(() => g.send("resume_game", 1));
  g.now += 20_000; g.send("resume_game"); assert.equal(g.room!.game_paused_total_seconds, 20);
  assert.equal(gameDeadline(g.room!), start + 80_000);
  g.now = start + 79_999; reject(() => g.send("finalize_expired_room", 1));
  g.now = start + 80_000; reject(() => g.send("request_vote", 1), "game_timer_elapsed");
  g.send("finalize_expired_room", 1); assert.equal(g.room!.winner, "spy"); assert.equal(g.history.length, 3);
  g.send("finish_room"); assert.equal(g.history.length, 3);
});

Deno.test("spy guess, unanimous replay auto-start, new match and stale source fencing", () => {
  const g = new Game().lobby().start(); const oldMatch = g.room!.match_id;
  const spy = g.actor(g.room!.spy_email); reject(() => g.send("submit_spy_guess", actors.slice(0, 3).find((a) => a.email !== spy.email)!, { guess: g.room!.word }));
  g.send("submit_spy_guess", spy, { guess: g.room!.word }); assert.equal(g.room!.winner, "spy");
  reject(() => g.send("reset_room_for_replay"));
  for (const actor of actors.slice(0, 2)) g.send("vote_play_again", actor);
  assert.equal(g.room!.status, "finished");
  g.send("vote_play_again", 2); assert.equal(g.room!.status, "roulette"); assert.equal(g.room!.replay_source_match_id, oldMatch);
  g.send("vote_play_again", 2, { expected_match_id: oldMatch }); assert.equal(g.room!.status, "roulette");
  g.now += 3001; g.send("complete_game_start", 1); assert.notEqual(g.room!.match_id, oldMatch);
  reject(() => g.send("submit_spy_guess", spy, { expected_match_id: oldMatch, guess: g.room!.word }), "room_match_generation_conflict");
});

Deno.test("host return, finished return, kick, leave/rejoin fence, host close and pre-timer departure", () => {
  const g = new Game().lobby(4).start();
  reject(() => g.send("vote_return_to_lobby", 1, { return_to_lobby_vote: true }));
  g.send("vote_return_to_lobby", 0, { return_to_lobby_vote: true }); assert.equal(g.room!.status, "waiting"); assert.equal(g.room!.match_id, "");
  const membership = g.room!.players[1].membership_id;
  g.send("leave_room", 1); g.send("join_room", 1, { client_capabilities: caps });
  reject(() => g.send("leave_room", 1, { expected_membership_id: membership }), "room_exit_membership_conflict");
  g.send("kick_player", 0, { target_email: actors[3].email }); assert.equal(g.room!.players.length, 3);
  g.start(); g.send("submit_spy_guess", g.actor(g.room!.spy_email), { guess: "Incorrect" });
  assert.equal(g.room!.winner, "detectives"); g.send("return_finished_room_to_lobby"); assert.equal(g.room!.status, "waiting");
  g.send("close_room"); assert.equal(g.room!.status, "ended"); reject(() => projectGame(g.room!, actors[1]));
  const h = new Game().lobby(); h.send("arm_roulette", 0, { expected_lobby_revision: h.room!.lobby_revision }); h.now += 3001; h.send("complete_game_start", 1);
  h.send("leave_room", 1); assert.equal(h.room!.status, "waiting"); assert.equal(h.history.length, 0);
});

Deno.test("active host departure transfers host, revokes projection and preserves terminal participant history", () => {
  const g = new Game().lobby(5).start();
  const before = g.room!.players.length; g.send("leave_room", 0);
  assert.notEqual(g.room!.host_email, actors[0].email); assert.equal(g.room!.players.length, before);
  assert.ok(g.room!.departed_player_emails.includes(actors[0].email)); reject(() => projectGame(g.room!, actors[0]), "room_departed");
  if (g.room!.status === "playing") { g.now = gameDeadline(g.room!)!; g.send("finalize_expired_room", g.actor(g.room!.host_email)); }
  assert.equal(g.history.length, 5);
  reject(() => g.send("record_finished_online_game", g.actor(g.room!.host_email)));
});

Deno.test("legacy explicit replay reset and unsupported actions", () => {
  const g = new Game().lobby().start(); g.send("submit_spy_guess", g.actor(g.room!.spy_email), { guess: "Wrong" });
  // Original older-client explicit reset remains valid for a persisted unanimous terminal snapshot.
  g.room!.ready_players = actors.slice(0, 3).map((a) => a.email);
  g.send("reset_room_for_replay"); assert.equal(g.room!.status, "waiting");
  reject(() => g.send("arbitrary_patch", 0, { spy_email: actors[0].email }), "unsupported_action");
  assert.equal(lobbyStateFromRoom(g.room!).lobby_word_pool.length, 3);
});
