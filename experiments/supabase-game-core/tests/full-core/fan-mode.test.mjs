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
const caps = ["multi_spy_v1", "fan_mode_v1"];
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
  "FAN real Auth, hidden all/no-spies, unanimous result and atomic idempotent history",
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
    await Promise.all(
      actors.slice(0, 3).map((a) => act(a, room, "request_vote")),
    );
    const voting = await snapshot(actors[0], room),
      target = scenario === "all_spies"
        ? "__fan_all_spies__"
        : "__fan_no_spies__";
    for (const actor of actors.slice(0, 3)) {
      await act(actor, room, "cast_detective_vote", {
        target_email: target,
        expected_vote_round_id: voting.detective_vote_round_id,
      });
    }
    assert.equal((await snapshot(actors[0], room)).status, "playing");
    const last = intent(
      actors[3],
      await snapshot(actors[3], room),
      "cast_detective_vote",
      {
        target_email: target,
        expected_vote_round_id: voting.detective_vote_round_id,
      },
      randomUUID(),
    );
    const replies = await Promise.all(
      Array.from({ length: 6 }, () => accepted(actors[3], last)),
    );
    for (const reply of replies) assert.deepEqual(reply, replies[0]);
    assert.equal(replies[0].room.winner, "all");
    assert.equal(replies[0].room.fan_scenario, scenario);
    assert.equal(replies[0].room.fan_result_reason, "correct_concept");
    const history =
      await db`select result from full_game_private.history where match_id=${room.match_id}`;
    assert.equal(history.length, 4);
    assert.ok(
      history.every((h) =>
        h.result.won === true && h.result.ranked === false &&
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
