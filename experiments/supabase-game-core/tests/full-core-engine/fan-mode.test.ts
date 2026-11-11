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
  sampleFanScenario,
} from "../../supabase/functions/full-game-core/rules/fan-mode-policy.ts";
import { aggregateCompetitiveStats, aggregateCompetitiveRoleStats, competitiveRatingDelta } from "../../supabase/functions/full-game-core/rules/competitive-stats.ts";
import { aggregateAchievementStats } from "../../supabase/functions/app-services/policies/achievements.ts";
import { assertRankedTerminalRoom, deriveExpiredGameWinner } from "../../supabase/functions/full-game-core/rules/room-result-policy.ts";
import { lobbyStateFromRoom } from "../../supabase/functions/full-game-core/rules/lobby-state-policy.ts";
const actors: GameActor[] = Array.from(
  { length: 12 },
  (_, i) => ({
    id: `00000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
    email: `agent${i}@example.test`,
    full_name: `Agent ${i}`,
  }),
);
const caps = ["multi_spy_v1", "fan_mode_v1", "fan_mode_v2", "fan_mode_v3"];
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
  lobby(all = 50, none = 20, count = 4, extra: GameRecord = {}) {
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
        ...extra,
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
Deno.test("FAN first player ejection draws for every participant, archives once and replays fresh", () => {
  for (const [all, none, scenario] of [[99, 0, "all_spies"], [0, 99, "no_spies"]] as const) {
    const m = new Mission().lobby(all, none).start();
    const round = m.open();
    for (const i of [1, 2]) {
      m.vote(i, actors[0].email, round);
      assert.equal(m.room!.status, "playing");
      assert.equal(projectGame(m.room!, actors[0]).fan_scenario, undefined);
    }
    m.vote(3, actors[0].email, round);
    assert.equal(m.room!.winner, "draw");
    assert.equal(m.room!.fan_result_reason, "player_ejected");
    assert.deepEqual(m.room!.eliminated_emails, [actors[0].email]);
    assert.deepEqual(m.room!.spectators, [actors[0].email]);
    assert.equal(m.history.length, 4);
    assert.ok(m.history.every((h) => h.won === null && h.winner === "draw" && !h.ranked && h.fan_scenario === scenario));
    for (const actor of actors.slice(0, 4)) {
      const view = projectGame(m.room!, actor);
      assert.equal(view.fan_scenario, scenario);
      assert.equal(view.winner, "draw");
      assert.deepEqual(view.eliminated_emails, [actors[0].email]);
    }
    m.send("finish_room");
    assert.equal(m.history.length, 4);
    const source = m.room!.match_id;
    m.random = .999;
    for (let i = 0; i < 4; i++) m.send("vote_play_again", i, { expected_match_id: source });
    assert.equal(m.room!.status, "roulette");
    assert.equal(m.room!.fan_scenario, "standard");
    assert.equal(m.room!.fan_result_reason, "");
    assert.equal(m.room!.spy_emails.length, 1);
    assert.deepEqual(m.room!.eliminated_emails, []);
  }
});
Deno.test("FAN rejects both retired concept choices in every scenario", () => {
  for (const [all, none] of [[99, 0], [0, 99], [0, 0]]) {
    const m = new Mission().lobby(all, none).start();
    m.open();
    for (const target of [FAN_ALL_SPIES_TARGET, FAN_NO_SPIES_TARGET, actors[0].email, actors[4].email]) {
      rejects(() => m.vote(0, target), "detective_vote_target_invalid");
    }
    assert.equal(m.room!.status, "playing");
    assert.deepEqual(m.room!.detective_votes, []);
    assert.equal(m.history.length, 0);
  }
});
Deno.test("mixed player votes cancel safely and cannot overwrite or replay an earlier ballot", () => {
  const m = new Mission().lobby().start();
  const old = m.open();
  m.vote(0, actors[1].email);
  rejects(() => m.vote(0, actors[2].email), "detective_vote_already_cast");
  m.vote(1, actors[0].email);
  m.vote(2, actors[3].email);
  m.vote(3, actors[2].email);
  assert.equal(m.room!.status, "playing");
  assert.equal(m.room!.detective_vote_round_id, "");
  assert.deepEqual(m.room!.eliminated_emails, []);
  m.open();
  assert.notEqual(m.room!.detective_vote_round_id, old);
  assert.throws(() => m.vote(2, actors[0].email, old));
});
Deno.test("resumed FAN ballots discard old concept votes and duplicate voters", () => {
  const m = new Mission().lobby().start();
  m.open();
  m.room!.detective_votes = [
    { voter_email: actors[0].email, voted_for_email: FAN_ALL_SPIES_TARGET },
    { voter_email: actors[1].email, voted_for_email: actors[0].email },
    { voter_email: actors[1].email, voted_for_email: actors[0].email },
  ];
  m.vote(2, actors[0].email);
  assert.equal(m.room!.status, "playing");
  assert.equal(m.room!.detective_votes.length, 2);
  m.vote(3, actors[0].email);
  assert.equal(m.room!.winner, "draw");
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
Deno.test("every FAN scenario opens a final player ballot at timeout instead of finishing", () => {
  for (const [all, none] of [[99, 0], [0, 99], [0, 0]]) {
    const m = new Mission().lobby(all, none).start();
    rejects(() => m.send("finalize_expired_room", 1), "invalid_ranked_terminal");
    m.now += 60000;
    rejects(() => deriveExpiredGameWinner(m.room!, m.now), "invalid_ranked_terminal");
    m.send("finalize_expired_room", 1);
    assert.equal(m.room!.status, "playing");
    assert.equal(m.room!.winner, "");
    assert.equal(m.history.length, 0);
    const round = m.room!.detective_vote_round_id;
    assert.ok(round);
    assert.equal(m.room!.vote_requests.length, 4);
    assert.equal(projectGame(m.room!, actors[0]).fan_scenario, undefined);
    const target = m.room!.fan_scenario === "standard" ? m.room!.spy_email : actors[0].email;
    const voters = actors.slice(0, 4).flatMap((a, i) => a.email === target ? [] : [i]);
    m.vote(voters[0], target, round);
    m.send("finalize_expired_room", 2);
    assert.equal(m.room!.detective_vote_round_id, round);
    assert.equal(m.room!.detective_votes.length, 1);
    m.vote(voters[1], target, round);
    m.vote(voters[2], target, round);
    assert.equal(m.room!.winner, m.room!.fan_scenario === "standard" ? "detectives" : "draw");
  }
});
Deno.test("FAN deadline preserves a live ballot and split votes reopen voting without revealing roles", () => {
  const m = new Mission().lobby().start();
  const round = m.open();
  m.vote(0, actors[1].email);
  m.now += 60000;
  m.send("finalize_expired_room", 1);
  assert.equal(m.room!.detective_vote_round_id, round);
  assert.equal(m.room!.detective_votes.length, 1);
  m.vote(1, actors[0].email);
  m.vote(2, actors[3].email);
  m.vote(3, actors[2].email);
  assert.equal(m.room!.status, "playing");
  assert.ok(m.room!.detective_vote_round_id);
  assert.notEqual(m.room!.detective_vote_round_id, round);
  assert.equal(m.room!.vote_requests.length, 4);
  assert.equal(m.history.length, 0);
  assert.equal(projectGame(m.room!, actors[0]).fan_scenario, undefined);
  for (let i = 1; i < 4; i++) m.vote(i, actors[0].email);
  assert.equal(m.room!.winner, "draw");
});
Deno.test("FAN departures preserve hidden roles and abandon an undersized match without a result", () => {
  for (const [all, none] of [[99, 0], [0, 99]]) {
    const d = new Mission().lobby(all, none).start();
    d.open();
    d.vote(0, actors[1].email);
    d.send("leave_room", 3);
    assert.equal(d.room!.status, "playing");
    assert.equal(d.room!.detective_vote_round_id, "");
    assert.deepEqual(projectGame(d.room!, actors[0]).revealed_spy_emails, []);
    d.send("leave_room", 2);
    assert.equal(d.room!.status, "ended");
    assert.equal(d.room!.winner, "");
    assert.equal(d.history.length, 0);
    const pre = new Mission().lobby(all, none);
    pre.send("arm_roulette", 0, { expected_lobby_revision: pre.room!.lobby_revision });
    pre.send("leave_room", 3);
    assert.equal(pre.room!.status, "waiting");
    assert.equal(pre.room!.fan_scenario, "");
  }
});
Deno.test("draw cannot be archived for a normal match or without a FAN ejection", () => {
  const m = new Mission().lobby().start();
  const finished = { ...m.room!, status: "finished", winner: "draw", fan_result_reason: "player_ejected" };
  rejects(() => assertRankedTerminalRoom(finished, "draw"), "invalid_ranked_terminal");
  rejects(() => assertRankedTerminalRoom({ ...finished, eliminated_emails: [actors[0].email], fan_scenario: "standard" }, "draw"), "invalid_ranked_terminal");
});
Deno.test("FAN draws are neutral for rating, wins, losses, role statistics and achievements", () => {
  const m = new Mission().lobby().start();
  m.open();
  for (let i = 1; i < 4; i++) m.vote(i, actors[0].email);
  assert.equal(aggregateCompetitiveStats(m.history).size, 0);
  assert.equal(aggregateCompetitiveRoleStats(m.history).size, 0);
  assert.equal(aggregateAchievementStats(m.history).size, 0);
  assert.ok(m.history.every((h) => competitiveRatingDelta(h) === 0));
  const corrupted = m.history.map((h) => ({ ...h, ranked: true, spy_count: 1, won: true }));
  assert.equal(aggregateCompetitiveStats(corrupted).size, 0);
  assert.equal(aggregateCompetitiveRoleStats(corrupted).size, 0);
  assert.equal(aggregateAchievementStats(corrupted).size, 0);
});
Deno.test("FAN v2 refuses old concept clients and lets an upgraded participant rejoin", () => {
  const m = new Mission().lobby();
  rejects(() => m.send("join_room", 4, { client_capabilities: ["multi_spy_v1", "fan_mode_v1"] }), "client_update_required");
  m.room!.players[1].client_capabilities = ["multi_spy_v1", "fan_mode_v1"];
  rejects(() => m.send("arm_roulette", 0, { expected_lobby_revision: m.room!.lobby_revision }), "client_update_required");
  rejects(() => projectGame(m.room!, actors[1]), "client_update_required");
  m.send("join_room", 1);
  assert.ok(projectGame(m.room!, actors[1]));
  m.start();
  m.room!.players[1].client_capabilities = ["multi_spy_v1", "fan_mode_v1"];
  m.now += 60000;
  m.send("join_room", 1);
  assert.ok(projectGame(m.room!, actors[1]));
  m.room!.fan_mode_enabled = false;
  m.room!.status = "waiting";
  m.room!.players[1].client_capabilities = [];
  rejects(() => m.send("update_lobby_state", 0, {
    mutation_id: m.uuid(), expected_revision: m.room!.lobby_revision,
    state: { ...lobbyStateFromRoom(m.room!), fan_mode_enabled: true },
  }), "client_update_required");
});

Deno.test("updated FAN client restores a stored v1 room and refreshes its own capabilities on action", () => {
  const m = new Mission().lobby().start();
  for (const p of m.room!.players) p.client_capabilities = ["multi_spy_v1", "fan_mode_v1"];
  assert.equal(projectGame(m.room!, actors[1], caps).status, "playing");
  rejects(() => projectGame(m.room!, actors[1], ["multi_spy_v1", "fan_mode_v1"]), "client_update_required");
  m.send("request_vote", 1);
  assert.ok(m.room!.players[1].client_capabilities.includes("fan_mode_v2"));
  assert.ok(!m.room!.players[0].client_capabilities.includes("fan_mode_v2"));
});


const extraDeals = ["split_words", "unique_words", "lone_civilian"] as const;
function extraDealMission(scenario: typeof extraDeals[number], count = 4) {
  return new Mission().lobby(0, 0, count, {
    [`fan_${scenario}_chance`]: 99,
    lobby_word_count: count,
    lobby_word_pool: Array.from({ length: count }, (_, i) => ({ id: `word-${i}`, word: `Word ${i}`, enabled: true })),
  });
}

Deno.test("FAN fresh defaults allocate two percent per surprise and ninety percent standard", () => {
  const defaults = fanSettings({});
  assert.deepEqual(defaults, {
    fan_mode_enabled: false,
    fan_all_spies_chance: 2,
    fan_no_spies_chance: 2,
    fan_split_words_chance: 2,
    fan_unique_words_chance: 2,
    fan_lone_civilian_chance: 2,
  });
  const counts: Record<string, number> = {};
  for (let roll = 0; roll < 100; roll++) {
    const scenario = sampleFanScenario(defaults, () => roll);
    counts[scenario] = (counts[scenario] || 0) + 1;
  }
  assert.deepEqual(counts, {
    all_spies: 2, no_spies: 2, split_words: 2, unique_words: 2, lone_civilian: 2, standard: 90,
  });
  const m = new Mission();
  m.send("create_room");
  assert.deepEqual(fanSettings(m.room!), defaults);
  assert.deepEqual(fanSettings(projectGame(m.room!, actors[0])), defaults);
  assert.deepEqual(fanSettings(lobbyStateFromRoom(m.room!)), defaults);
});

Deno.test("FAN legacy and custom probabilities preserve explicit zero without enabling new deals", () => {
  const legacy = { fan_all_spies_chance: 35, fan_no_spies_chance: 25 };
  assert.deepEqual(fanSettings(legacy), {
    fan_mode_enabled: false,
    ...legacy,
    fan_split_words_chance: 0,
    fan_unique_words_chance: 0,
    fan_lone_civilian_chance: 0,
  });
  for (const oldField of ["fan_all_spies_chance", "fan_no_spies_chance"]) {
    const settings = fanSettings({ [oldField]: 0 });
    assert.equal(settings[oldField as keyof typeof settings], 0);
    for (const scenario of extraDeals) assert.equal(settings[`fan_${scenario}_chance`], 0);
  }
  const custom = {
    fan_mode_enabled: true,
    fan_all_spies_chance: 0,
    fan_no_spies_chance: 0,
    fan_split_words_chance: 0,
    fan_unique_words_chance: 0,
    fan_lone_civilian_chance: 0,
  };
  assert.deepEqual(fanSettings(custom), custom);
  assert.equal(sampleFanScenario(custom, () => 0), "standard");
  assert.deepEqual(fanSettings({ fan_all_spies_chance: null, fan_no_spies_chance: null }), fanSettings({}));
});

Deno.test("FAN extra probability boundaries reject invalid totals", () => {
  const settings = { fan_all_spies_chance: 10, fan_no_spies_chance: 10, fan_split_words_chance: 20, fan_unique_words_chance: 20, fan_lone_civilian_chance: 20 };
  for (const [roll, scenario] of [[0, "all_spies"], [9, "all_spies"], [10, "no_spies"], [19, "no_spies"], [20, "split_words"], [39, "split_words"], [40, "unique_words"], [59, "unique_words"], [60, "lone_civilian"], [79, "lone_civilian"], [80, "standard"], [99, "standard"]] as const) {
    assert.equal(sampleFanScenario(settings, () => roll), scenario);
  }
  for (const field of extraDeals.map((s) => `fan_${s}_chance`)) {
    for (const value of [-1, 100, 1.5, "15", NaN]) rejects(() => fanSettings({ [field]: value }), "fan_settings_invalid");
  }
  rejects(() => fanSettings({ ...settings, fan_lone_civilian_chance: 41 }), "fan_settings_invalid");
});

Deno.test("FAN new deals freeze balanced/private words and a lone civilian across odd/even rosters", () => {
  for (const scenario of extraDeals) for (const count of [3, 4, 5, 12]) {
    const m = extraDealMission(scenario, count);
    m.send("arm_roulette", 0, { expected_lobby_revision: m.room!.lobby_revision });
    const frozen = structuredClone(m.room!);
    m.random = .999;
    m.send("arm_roulette", 0);
    assert.equal(m.room!.fan_scenario, scenario);
    assert.deepEqual(m.room!.spy_emails, frozen.spy_emails);
    assert.deepEqual(m.room!.fan_player_words, frozen.fan_player_words);
    const words = Object.values(m.room!.fan_player_words) as string[];
    assert.equal(m.room!.spy_emails.length, scenario === "lone_civilian" ? count - 1 : 0);
    assert.equal(words.length, scenario === "lone_civilian" ? 1 : count);
    assert.equal(new Set(words).size, scenario === "split_words" ? 2 : scenario === "unique_words" ? count : 1);
    if (scenario === "split_words") {
      const firstCount = words.filter((w) => w === words[0]).length;
      assert.ok(Math.abs(firstCount - (count - firstCount)) <= 1);
    }
    m.now += 3001;
    m.send("complete_game_start", 1);
    for (let i = 0; i < count; i++) m.send("mark_role_card_read", i);
    assert.equal(m.room!.status, "playing");
    assert.equal(m.room!.winner, "");
    for (const actor of actors.slice(0, count)) {
      const view = projectGame(m.room!, actor);
      assert.equal(view.fan_scenario, undefined);
      assert.equal(view.fan_player_words, undefined);
      assert.equal(view.word, m.room!.fan_player_words[actor.email] || "CLASSIFIED");
      assert.equal(view.secret_word, view.word);
      assert.deepEqual(view.revealed_spy_emails, []);
      assert.ok(view.spy_emails.length <= 1);
      assert.equal(view.exclusion_vote_threshold, count - 1);
    }
    m.open();
    for (let i = 1; i < count; i++) m.vote(i, actors[0].email);
    assert.equal(m.room!.winner, "draw");
    assert.equal(m.history.length, count);
    assert.ok(m.history.every((h) => h.won === null && !h.ranked && h.fan_scenario === scenario));
    assert.equal(aggregateCompetitiveStats(m.history).size, 0);
    assert.equal(aggregateAchievementStats(m.history).size, 0);
    for (const actor of actors.slice(0, count)) {
      const view = projectGame(m.room!, actor);
      assert.equal(view.fan_scenario, scenario);
      assert.deepEqual(view.fan_player_words, frozen.fan_player_words);
    }
  }
});

Deno.test("FAN unique words reject insufficient distinct enabled words before any start is committed", () => {
  const m = new Mission().lobby(0, 0, 4, { fan_unique_words_chance: 1 });
  m.random = .99;
  const lobby = structuredClone(m.room);
  rejects(() => m.send("arm_roulette", 0, { expected_lobby_revision: m.room!.lobby_revision }), "fan_word_pool_incomplete");
  assert.deepEqual(m.room, lobby);
  m.room!.lobby_word_pool.push({ id: "dupe", word: " MUSEUM ", enabled: true }, { id: "disabled", word: "Bridge", enabled: false });
  rejects(() => m.send("arm_roulette", 0, { expected_lobby_revision: m.room!.lobby_revision }), "fan_word_pool_incomplete");
});

Deno.test("FAN extra deals require v3 without forcing old-only FAN rooms to upgrade", () => {
  const oldCaps = ["multi_spy_v1", "fan_mode_v1", "fan_mode_v2"];
  const legacy = new Mission().lobby();
  assert.ok(projectGame(legacy.room!, actors[0], oldCaps));
  assert.deepEqual(extraDeals.map((scenario) => legacy.room![`fan_${scenario}_chance`]), [0, 0, 0]);
  const fresh = new Mission().lobby(2, 2, 4, { ...fanSettings({}), fan_mode_enabled: true });
  rejects(() => projectGame(fresh.room!, actors[0], oldCaps), "client_update_required");
  rejects(() => fresh.send("join_room", 4, { client_capabilities: oldCaps }), "client_update_required");
  assert.ok(projectGame(fresh.room!, actors[0], caps));
  fresh.room!.fan_mode_enabled = false;
  assert.ok(projectGame(fresh.room!, actors[0], oldCaps));
  for (const scenario of extraDeals) {
    const m = extraDealMission(scenario);
    rejects(() => projectGame(m.room!, actors[0], oldCaps), "client_update_required");
    rejects(() => m.send("join_room", 4, { client_capabilities: oldCaps }), "client_update_required");
    m.room!.players[1].client_capabilities = oldCaps;
    rejects(() => m.send("arm_roulette", 0, { expected_lobby_revision: m.room!.lobby_revision }), "client_update_required");
    m.send("join_room", 1);
    m.start();
    assert.ok(projectGame(m.room!, actors[1], caps));
  }
});

Deno.test("FAN extra deals replay with fresh assignments and clear maps when returning to lobby", () => {
  for (const scenario of extraDeals) {
    const m = extraDealMission(scenario).start();
    m.open();
    for (let i = 1; i < 4; i++) m.vote(i, actors[0].email);
    m.room!.fan_player_words["stale@example.test"] = "Previous round";
    const source = m.room!.match_id;
    m.random = .2;
    for (let i = 0; i < 4; i++) m.send("vote_play_again", i, { expected_match_id: source });
    assert.equal(m.room!.status, "roulette");
    assert.equal(m.room!.fan_scenario, scenario);
    assert.equal(m.room!.fan_player_words["stale@example.test"], undefined);
    assert.equal(Object.keys(m.room!.fan_player_words).length, scenario === "lone_civilian" ? 1 : 4);
    assert.equal(projectGame(m.room!, actors[0]).fan_player_words, undefined);
    m.send("leave_room", 3);
    assert.equal(m.room!.status, "waiting");
    assert.equal(m.room!.fan_scenario, "");
    assert.deepEqual(m.room!.fan_player_words, {});
  }
});
