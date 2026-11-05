import assert from "node:assert/strict";
import {
  type GameActor,
  type GameRecord,
  projectGame,
  reduceGame,
} from "../../supabase/functions/full-game-core/engine.ts";
import {
  FAN_ALL_SPIES_TARGET,
  FAN_NO_SPIES_TARGET,
  fanSettings,
} from "../../supabase/functions/full-game-core/rules/fan-mode-policy.ts";
import { lobbyStateFromRoom } from "../../supabase/functions/full-game-core/rules/lobby-state-policy.ts";
const actors: GameActor[] = Array.from(
  { length: 12 },
  (_, i) => ({
    id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
    email: `agent${i}@example.test`,
    full_name: `Agent ${i}`,
  }),
);
const caps = ["multi_spy_v1", "fan_mode_v1"];
class Mission {
  room: GameRecord | null = null;
  now = Date.parse("2026-11-05T12:00:00Z");
  serial = 100;
  history: GameRecord[] = [];
  random = 0.31;
  uuid = () =>
    `00000000-0000-4000-8000-${String(++this.serial).padStart(12, "0")}`;
  send(action: string, who = 0, payload: GameRecord = {}) {
    const p = this.room?.players.find((p: GameRecord) =>
      p.email === actors[who].email
    );
    const result = reduceGame({
      room: this.room,
      actor: actors[who],
      action,
      payload: {
        expected_match_id: this.room?.match_id,
        expected_membership_id: p?.membership_id,
        client_capabilities: caps,
        ...payload,
      },
      now: this.now,
      uuid: this.uuid,
      random: () => this.random,
      roomID: this.uuid(),
      roomCode: "FAN123",
    });
    result.room.room_revision = Number(this.room?.room_revision || 0) + 1;
    this.room = result.room;
    this.history.push(...result.history || []);
    return result;
  }
  lobby(all = 50, none = 20, count = 4) {
    this.send("create_room", 0, { client_capabilities: caps });
    for (let i = 1; i < count; i++) {
      this.send("join_room", i, { client_capabilities: caps });
    }
    this.send("update_lobby_state", 0, {
      mutation_id: this.uuid(),
      expected_revision: 0,
      state: {
        game_mode: "questions",
        game_duration_seconds: 60,
        lobby_spy_count: 1,
        spies_know_each_other: true,
        fan_mode_enabled: true,
        fan_all_spies_chance: all,
        fan_no_spies_chance: none,
        lobby_word_source: "manual",
        lobby_word_count: 2,
        lobby_word_count_mode: "custom",
        lobby_word_pool: [{ id: "a", word: "Museum", enabled: true }, {
          id: "b",
          word: "Airport",
          enabled: true,
        }],
      },
    });
    return this;
  }
  start() {
    this.send("arm_roulette", 0, {
      expected_lobby_revision: this.room!.lobby_revision,
    });
    this.now += 3001;
    this.send("complete_game_start", 1);
    for (let i = 0; i < this.room!.players.length; i++) {
      this.send("mark_role_card_read", i);
    }
    return this;
  }
  open() {
    for (
      let i = 0;
      i < Math.ceil(
        this.room!.players.filter((p: GameRecord) =>
          !this.room!.spectators.includes(p.email)
        ).length * .51,
      );
      i++
    ) this.send("request_vote", i);
    return this.room!.detective_vote_round_id;
  }
  vote(
    who: number,
    target: string,
    round = this.room!.detective_vote_round_id,
  ) {
    return this.send("cast_detective_vote", who, {
      target_email: target,
      expected_vote_round_id: round,
    });
  }
}
function rejects(fn: () => unknown, code: string) {
  assert.throws(fn, (e: any) => e.code === code);
}
Deno.test("FAN settings enforce bounded probabilities and canonical single-spy lobby", () => {
  for (const [a, n] of [[99, 99], [-1, 0], [0, 100], [1.5, 0]]) {
    rejects(
      () => fanSettings({ fan_all_spies_chance: a, fan_no_spies_chance: n }),
      "fan_settings_invalid",
    );
  }
  assert.equal(
    fanSettings({ fan_all_spies_chance: 99, fan_no_spies_chance: 1 })
      .fan_all_spies_chance,
    99,
  );
  const m = new Mission().lobby();
  assert.equal(m.room!.lobby_spy_count, 1);
  assert.equal(m.room!.spies_know_each_other, false);
  assert.equal(projectGame(m.room!, actors[0]).fan_all_spies_chance, 50);
});
Deno.test("FAN sampling freezes all/no/standard roles, no auto-win or secret concept leak", () => {
  for (
    const [all, none, scenario, count] of [[99, 0, "all_spies", 12], [
      0,
      99,
      "no_spies",
      4,
    ], [0, 0, "standard", 4]] as const
  ) {
    const m = new Mission().lobby(all, none, count);
    m.send("arm_roulette", 0, {
      expected_lobby_revision: m.room!.lobby_revision,
    });
    const original = structuredClone(m.room!);
    m.random = .999;
    m.send("arm_roulette", 0);
    assert.equal(m.room!.fan_scenario, scenario);
    assert.deepEqual(m.room!.spy_emails, original.spy_emails);
    assert.equal(m.room!.word, original.word);
    m.now += 3001;
    m.send("complete_game_start", 1);
    for (let i = 0; i < count; i++) m.send("mark_role_card_read", i);
    assert.equal(m.room!.status, "playing");
    assert.equal(
      m.room!.spy_emails.length,
      scenario === "all_spies" ? count : scenario === "no_spies" ? 0 : 1,
    );
    for (let i = 0; i < count; i++) {
      const v = projectGame(m.room!, actors[i]);
      assert.equal(v.fan_scenario, undefined);
      assert.equal(v.fan_result_reason, undefined);
      assert.equal(v.exclusion_vote_threshold, count - 1);
      assert.ok(v.spy_emails.length <= 1);
      assert.deepEqual(v.revealed_spy_emails, []);
      assert.equal(
        v.word,
        scenario === "all_spies"
          ? "CLASSIFIED"
          : scenario === "no_spies"
          ? m.room!.word
          : m.room!.spy_email === actors[i].email
          ? "CLASSIFIED"
          : m.room!.word,
      );
    }
    rejects(
      () => m.send("submit_spy_guess", 0, { guess: m.room!.word }),
      "fan_guess_disabled",
    );
  }
});
Deno.test("FAN requires every active vote for concept, archives cooperative win once and replays fresh", () => {
  const m = new Mission().lobby().start();
  const round = m.open();
  for (let i = 0; i < 3; i++) {
    m.vote(i, FAN_ALL_SPIES_TARGET, round);
    assert.equal(m.room!.status, "playing");
  }
  m.vote(3, FAN_ALL_SPIES_TARGET, round);
  assert.equal(m.room!.winner, "all");
  assert.equal(m.room!.fan_result_reason, "correct_concept");
  assert.equal(m.history.length, 4);
  assert.ok(
    m.history.every((h) =>
      h.won && !h.ranked && h.fan_scenario === "all_spies"
    ),
  );
  assert.equal(projectGame(m.room!, actors[0]).fan_scenario, "all_spies");
  m.send("finish_room");
  assert.equal(m.history.length, 4);
  const source = m.room!.match_id;
  m.random = .99;
  for (let i = 0; i < 4; i++) {
    m.send("vote_play_again", i, { expected_match_id: source });
  }
  assert.equal(m.room!.status, "roulette");
  assert.equal(m.room!.fan_scenario, "standard");
  assert.equal(m.room!.fan_result_reason, "");
  assert.equal(m.room!.spy_emails.length, 1);
});
Deno.test("wrong unanimous concept loses to system including normal scenario", () => {
  for (const [all, none] of [[99, 0], [0, 0]]) {
    const m = new Mission().lobby(all, none).start();
    m.open();
    for (let i = 0; i < 4; i++) m.vote(i, FAN_NO_SPIES_TARGET);
    assert.equal(m.room!.winner, "system");
    assert.equal(m.room!.fan_result_reason, "wrong_concept");
    assert.ok(m.history.every((h) => !h.won && !h.ranked));
  }
});
Deno.test("mixed FAN votes cancel safely and cannot overwrite or replay an earlier ballot", () => {
  const m = new Mission().lobby().start();
  const old = m.open();
  m.vote(0, FAN_ALL_SPIES_TARGET);
  rejects(() => m.vote(0, FAN_NO_SPIES_TARGET), "detective_vote_already_cast");
  m.vote(1, FAN_NO_SPIES_TARGET);
  assert.equal(m.room!.detective_vote_round_id, old);
  m.vote(2, FAN_ALL_SPIES_TARGET);
  m.vote(3, FAN_NO_SPIES_TARGET);
  assert.equal(m.room!.status, "playing");
  assert.equal(m.room!.detective_vote_round_id, "");
  assert.deepEqual(m.room!.eliminated_emails, []);
  m.open();
  assert.notEqual(m.room!.detective_vote_round_id, old);
  assert.throws(() => m.vote(2, FAN_ALL_SPIES_TARGET, old));
});
Deno.test("accusing a player in anomalous round loses to system without revealing intermediate roles", () => {
  for (const [all, none] of [[99, 0], [0, 99]]) {
    const m = new Mission().lobby(all, none).start();
    m.open();
    for (let i = 1; i < 4; i++) m.vote(i, actors[0].email);
    assert.equal(m.room!.winner, "system");
    assert.equal(m.room!.fan_result_reason, "wrong_accusation");
    assert.deepEqual(m.room!.eliminated_emails, []);
  }
});
Deno.test("standard FAN preserves normal accusation victory and excludes competitive rating", () => {
  const m = new Mission().lobby(0, 0).start();
  m.open();
  for (let i = 0; i < 4; i++) {
    if (actors[i].email !== m.room!.spy_email) m.vote(i, m.room!.spy_email);
  }
  assert.equal(m.room!.winner, "detectives");
  assert.ok(m.history.every((h) => !h.ranked));
  assert.equal(m.history.filter((h) => h.won).length, 3);
});
Deno.test("FAN timeout and departures cannot accidentally turn no/all-spies into team win", () => {
  for (const [all, none] of [[99, 0], [0, 99]]) {
    const m = new Mission().lobby(all, none).start();
    m.now += 60000;
    m.send("finalize_expired_room", 1);
    assert.equal(m.room!.winner, "system");
    assert.equal(m.room!.fan_result_reason, "timeout");
    const d = new Mission().lobby(all, none).start();
    d.open();
    d.vote(0, FAN_ALL_SPIES_TARGET);
    d.send("leave_room", 3);
    assert.equal(d.room!.status, "playing");
    assert.equal(d.room!.detective_vote_round_id, "");
    assert.deepEqual(projectGame(d.room!, actors[0]).revealed_spy_emails, []);
    d.send("leave_room", 2);
    assert.equal(d.room!.winner, "system");
    assert.equal(d.room!.fan_result_reason, "insufficient_players");
    const pre = new Mission().lobby(all, none);
    pre.send("arm_roulette", 0, {
      expected_lobby_revision: pre.room!.lobby_revision,
    });
    pre.send("leave_room", 3);
    assert.equal(pre.room!.status, "waiting");
    assert.equal(pre.room!.fan_scenario, "");
  }
});
Deno.test("FAN refuses legacy participants when enabled and legacy joins/restores", () => {
  const m = new Mission().lobby();
  rejects(
    () => m.send("join_room", 4, { client_capabilities: ["multi_spy_v1"] }),
    "client_update_required",
  );
  m.room!.players[1].client_capabilities = [];
  rejects(
    () =>
      m.send("arm_roulette", 0, {
        expected_lobby_revision: m.room!.lobby_revision,
      }),
    "client_update_required",
  );
  rejects(() => projectGame(m.room!, actors[1]), "client_update_required");
  m.room!.fan_mode_enabled = false;
  rejects(
    () =>
      m.send("update_lobby_state", 0, {
        mutation_id: m.uuid(),
        expected_revision: m.room!.lobby_revision,
        state: { ...lobbyStateFromRoom(m.room!), fan_mode_enabled: true },
      }),
    "client_update_required",
  );
});
