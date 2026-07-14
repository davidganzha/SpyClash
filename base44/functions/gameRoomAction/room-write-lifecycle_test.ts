import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertExactRoomLeaseCoverage,
  assertRoomWriterLeaseForUser,
  uniqueStableUserIDs,
} from "./room-write-lifecycle.ts";

Deno.test("room lifecycle identities are stable, unique and deadlock ordered", () => {
  assertEquals(
    uniqueStableUserIDs([" user-z ", "user-a", "user-z", null, ""]),
    ["user-a", "user-z"],
  );
});

Deno.test("stale room snapshot cannot cover a participant who joined while leases were acquired", () => {
  const staleLeaseContext = {
    lifecycleStore: {},
    userIDs: ["host-user", "player-a"],
    leases: [],
  };

  const error = assertThrows(
    () =>
      assertExactRoomLeaseCoverage(staleLeaseContext, [
        "host-user",
        "player-a",
        "concurrent-joiner",
      ]),
    Error,
    "Room membership changed",
  );
  assertEquals((error as Error & { status?: number }).status, 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_membership_changed",
  );
});

Deno.test("exact participant set is independent of ordering and duplicates", () => {
  assertExactRoomLeaseCoverage({
    lifecycleStore: {},
    userIDs: ["host-user", "player-a"],
    leases: [],
  }, ["player-a", "host-user", "player-a"]);
});

Deno.test("history persistence cannot borrow another participant's lease", async () => {
  const error = await assertRejects(
    () =>
      assertRoomWriterLeaseForUser({
        lifecycleStore: {},
        userIDs: ["host-user"],
        leases: [{} as any],
      }, "concurrent-joiner"),
    Error,
    "Room membership changed",
  );
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_membership_changed",
  );
});
