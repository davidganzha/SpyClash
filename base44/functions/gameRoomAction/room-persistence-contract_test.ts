import { assert, assertStringIncludes } from "jsr:@std/assert@1";

Deno.test("room writes use lifecycle-serialized entity id operations", async () => {
  const source = await Deno.readTextFile(
    new URL("./main.ts", import.meta.url),
  );

  assert(
    !source.includes("entities.GameRoom.updateMany("),
    "GameRoom must not CAS against Base44's system updated_date field",
  );
  assert(
    !source.includes("entities.GameRoom.deleteMany("),
    "GameRoom deletion must use the stable entity id under writer leases",
  );
  assertStringIncludes(
    source,
    "entities.GameRoom.update(latest.id",
  );
  assertStringIncludes(
    source,
    "deleteRoomAndVerify({",
  );
  assertStringIncludes(
    source,
    "updateRoomWithRetry(\n    base44,\n    room,",
  );
  assertStringIncludes(
    source,
    'action === "leave_room" && leaveAlreadyComplete(room, user.email)',
  );
});
