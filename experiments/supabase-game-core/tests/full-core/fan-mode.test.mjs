import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test, { after, before } from "node:test";
import postgres from "postgres";
import {
  accepted,
  act,
  createActor,
  intent,
  playing,
  snapshot,
} from "./fixtures.mjs";
const db = postgres(process.env.DATABASE_URL, {
  max: 4,
  idle_timeout: 10,
  connect_timeout: 10,
});
const actors = [], legacy = [];
const caps = ["multi_spy_v1", "fan_mode_v1", "fan_mode_v2"];
before(async () => {
  for (let i = 0; i < 4; i++) {
    const actor = await createActor(i);
    legacy.push(actor);
    actors.push({
      ...actor,
      send(body, options) {
        return actor.send({
          ...body,
          client_capabilities: caps,
          ...(body.player
            ? { player: { ...body.player, client_capabilities: caps } }
            : {}),
        }, options);
      },
    });
  }
});
after(async () => {
  await Promise.all(actors.map((a) => a.close()));
  await db.end();
});
test(
  "FAN real Auth, hidden all/no-spies, ejection draw and atomic idempotent history",
  { timeout: 60000 },
  async () => {
    // 99/1 guarantees an anomaly without adding an insecure forced-scenario API.
    const room = await playing(actors, {
      fan_mode_enabled: true,
      fan_all_spies_chance: 99,
      fan_no_spies_chance: 1,
    });
    const [stored] =
      await db`select state from full_game_private.rooms where id=${room.id}`;
    const scenario = stored.state.fan_scenario;
    assert.ok(["all_spies", "no_spies"].includes(scenario));
    const views = await Promise.all(actors.map((a) => snapshot(a, room)));
    for (const v of views) {
      assert.equal(v.fan_scenario, undefined);
      assert.equal(v.exclusion_vote_threshold, 3);
      assert.ok(v.spy_emails.length <= 1);
      assert.equal(v.lobby_spy_count, 1);
      assert.equal(v.status, "playing");
    }
    assert.equal(
      (await legacy[0].send({ action: "get_room", room_id: room.id })).status,
      426,
      "Stored capabilities must not authorize an old client restore",
    );
    assert.equal(
      (await legacy[0].send(intent(legacy[0], room, "request_vote"))).status,
      426,
    );
    // Simulate clients restoring a match whose frozen roster predates v2.
    await db`update full_game_private.rooms set state = jsonb_set(state, '{players}',
      (select jsonb_agg(jsonb_set(p, '{client_capabilities}', '["multi_spy_v1","fan_mode_v1"]'::jsonb))
       from jsonb_array_elements(state->'players') p)) where id=${room.id}`;
    assert.equal((await snapshot(actors[0], room)).status, "playing");
    await Promise.all(
      actors.slice(0, 3).map((a) => act(a, room, "request_vote")),
    );
    const voting = await snapshot(actors[0], room);
    const target = actors[0].email;
    for (const concept of ["__fan_all_spies__", "__fan_no_spies__"]) {
      const rejected = await actors[1].send(intent(actors[1], voting, "cast_detective_vote", {
        target_email: concept, expected_vote_round_id: voting.detective_vote_round_id,
      }));
      assert.equal(rejected.status, 400);
      assert.equal(rejected.body.code, "detective_vote_target_invalid");
    }
    for (const actor of actors.slice(1, 3)) {
      await act(actor, room, "cast_detective_vote", {
        target_email: target,
        expected_vote_round_id: voting.detective_vote_round_id,
      });
    }
    assert.equal((await snapshot(actors[0], room)).status, "playing");
    const last = intent(
      actors[3], await snapshot(actors[3], room), "cast_detective_vote",
      { target_email: target, expected_vote_round_id: voting.detective_vote_round_id }, randomUUID(),
    );
    const replies = await Promise.all(
      Array.from({ length: 6 }, () => accepted(actors[3], last)),
    );
    for (const reply of replies) assert.deepEqual(reply, replies[0]);
    assert.equal(replies[0].room.winner, "draw");
    assert.deepEqual(replies[0].room.eliminated_emails, [target]);
    for (const actor of actors) {
      const view = await snapshot(actor, room);
      assert.equal(view.winner, "draw");
      assert.equal(view.fan_scenario, scenario);
    }
    assert.equal(replies[0].room.fan_scenario, scenario);
    assert.equal(replies[0].room.fan_result_reason, "player_ejected");
    const history =
      await db`select result from full_game_private.history where match_id=${room.match_id}`;
    assert.equal(history.length, 4);
    assert.ok(
      history.every((h) =>
        h.result.won === null && h.result.winner === "draw" && h.result.ranked === false &&
        h.result.fan_scenario === scenario
      ),
    );
    assert.equal(
      (await db`select 1 from full_game_private.outbox where room_id=${room.id} and event->>'type'='game_finished'`)
        .length,
      1,
    );
  },
);
