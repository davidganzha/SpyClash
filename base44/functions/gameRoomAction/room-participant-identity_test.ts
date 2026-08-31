import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { storedRoomParticipantUserIDs } from "./room-participant-identity.ts";

const players = [
  { user_id: "user-a", email: "a@spyclash.test" },
  { user_id: "user-b", email: "b@spyclash.test" },
];

Deno.test("stable room participant IDs bypass legacy email resolution", () => {
  assertEquals(
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-b", "user-a"],
      hostEmail: "A@SpyClash.Test",
      actor: { id: "user-b", email: "b@spyclash.test" },
    }),
    ["user-a", "user-b"],
  );
});

Deno.test("incomplete participant index falls back to migration", () => {
  assertEquals(
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-a"],
      hostEmail: "a@spyclash.test",
    }),
    null,
  );
});

Deno.test("stable actor mismatch fails closed", () => {
  const error = assertThrows(() =>
    storedRoomParticipantUserIDs({
      players,
      participantUserIDs: ["user-a", "user-b"],
      hostEmail: "a@spyclash.test",
      actor: { id: "attacker", email: "b@spyclash.test" },
    })
  );
  assertEquals((error as Error & { status?: number }).status, 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "participant_identity_mismatch",
  );
});
