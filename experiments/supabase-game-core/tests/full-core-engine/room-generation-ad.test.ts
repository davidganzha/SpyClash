import assert from "node:assert/strict";
import { reduceGame, projectGame, type GameRecord, type GameActor } from "../../supabase/functions/full-game-core/engine.ts";
import { roomGenerationAdPatch as base44Patch } from "../../../../base44/functions/gameRoomAction/room-generation-ad.ts";

const actors: GameActor[] = Array.from({ length: 3 }, (_, i) => ({ id: `00000000-0000-4000-8000-00000000000${i + 1}`, email: `player${i}@example.test`, full_name: `Player ${i}` }));
const first = "10000000-0000-4000-8000-000000000001", second = "10000000-0000-4000-8000-000000000002";
class Room {
  state: GameRecord | null = null;
  now = Date.parse("2030-01-01T12:00:00Z");
  send(action: string, actor = actors[0], payload: GameRecord = {}) {
    const player = this.state?.players.find((p: GameRecord) => p.email === actor.email);
    const out = reduceGame({ room: this.state, actor, action, payload: { ...(player ? { expected_membership_id: player.membership_id } : {}), ...payload }, now: this.now, roomID: "20000000-0000-4000-8000-000000000001", roomCode: "ABC234" });
    this.state = out.room; return out;
  }
  constructor() {
    this.send("create_room", actors[0], { client_capabilities: ["multi_spy_v1"] });
    for (const actor of actors.slice(1)) this.send("join_room", actor, { client_capabilities: ["multi_spy_v1"] });
  }
}
const signal = (id = first, state = "presenting") => ({ generation_ad_session_id: id, generation_ad_state: state });
Deno.test("three-player room shares only host presentation metadata, guests cannot create or end it", () => {
  const room = new Room();
  const before = structuredClone(room.state!);
  for (const guest of actors.slice(1)) assert.throws(() => room.send("set_generation_ad", guest, signal()), { code: "room_ad_host_required" });
  const output = room.send("set_generation_ad", actors[0], { ...signal(), access_token: "never-project", custom_data: "never-project" });
  assert.deepEqual(output.history, undefined); assert.deepEqual(output.events, undefined);
  assert.deepEqual(room.state!.players, before.players);
  assert.equal(room.state!.lobby_revision, before.lobby_revision);
  const projected = actors.map(actor => projectGame(room.state!, actor).room_generation_ad);
  assert.deepEqual(projected[0], projected[1]); assert.deepEqual(projected[1], projected[2]);
  assert.deepEqual(Object.keys(projected[0]).sort(), ["expires_at", "host_email", "id", "started_at"]);
  assert.equal(Date.parse(projected[0].expires_at) - Date.parse(projected[0].started_at), 180_000);
  for (const guest of actors.slice(1)) assert.throws(() => room.send("set_generation_ad", guest, signal(first, "ended")), { code: "room_ad_host_required" });
  // Both guests can decline or lack an ad: no guest acknowledgement exists in
  // the command. Host completion alone dismisses all room prompts.
  room.send("set_generation_ad", actors[0], signal(first, "ended"));
  for (const actor of actors) assert.equal(projectGame(room.state!, actor).room_generation_ad, null);
  assert.equal(room.state!.status, "waiting");
  room.send("begin_ready_check"); assert.equal(room.state!.status, "ready_voting");
});
Deno.test("duplicate begin does not extend TTL, stale end cannot dismiss a newer host ad", () => {
  const room = new Room(); room.send("set_generation_ad", actors[0], signal());
  const original = structuredClone(room.state!.room_generation_ad);
  room.now += 1000; room.send("set_generation_ad", actors[0], signal());
  assert.deepEqual(room.state!.room_generation_ad, original);
  room.send("set_generation_ad", actors[0], signal(second));
  room.send("set_generation_ad", actors[0], signal(first, "ended"));
  assert.equal(room.state!.room_generation_ad.id, second);
  room.state!.host_email = actors[1].email;
  for (const actor of actors) assert.equal(projectGame(room.state!, actor).room_generation_ad, null);
});
Deno.test("Base44 and native reducer use identical host-only bounded presentation policy", () => {
  const room = new Room();
  const expected = base44Patch(room.state!, actors[0], signal(), room.now);
  room.send("set_generation_ad", actors[0], signal());
  assert.deepEqual(room.state!.room_generation_ad, expected.room_generation_ad);
  assert.throws(() => base44Patch(room.state!, actors[1], signal(), room.now), { code: "room_ad_host_required" });
  room.state!.status = "playing";
  assert.throws(() => room.send("set_generation_ad", actors[0], signal(second)), { code: "room_ad_lobby_required" });
});
