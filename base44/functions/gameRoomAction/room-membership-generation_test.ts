import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertExpectedMembershipGeneration,
  captureRoomExitMembershipGeneration,
  playerMembershipGeneration,
  validatedMembershipGeneration,
  viewerMembershipGeneration,
} from "./room-membership-generation.ts";

Deno.test("unrelated room revisions do not invalidate one membership generation", () => {
  const player = {
    user_id: "user-1",
    email: "one@example.com",
    membership_id: "membership_generation_1",
  };
  const before = { id: "room-1", room_revision: 4, players: [player] };
  const afterVote = { ...before, room_revision: 9 };
  assertExpectedMembershipGeneration({
    room: afterVote,
    user: { id: "user-1", email: "one@example.com" },
    expected: viewerMembershipGeneration(before, { id: "user-1" }),
  });
});

Deno.test("a delayed exit cannot remove a later rejoin generation", () => {
  const room = {
    id: "room-1",
    players: [{
      user_id: "user-1",
      email: "one@example.com",
      membership_id: "membership_generation_2",
    }],
  };
  const stale = assertThrows(
    () =>
      assertExpectedMembershipGeneration({
        room,
        user: { id: "user-1", email: "one@example.com" },
        expected: "membership_generation_1",
      }),
    Error,
  ) as Error & { status?: number; code?: string };
  assertEquals(stale.status, 409);
  assertEquals(stale.code, "room_exit_membership_conflict");
});

Deno.test("legacy exit captures the server membership before a delayed rejoin", () => {
  const user = { id: "user-1", email: "one@example.com" };
  const initialRoom = {
    id: "room-1",
    room_revision: 4,
    players: [{
      ...user,
      membership_id: "membership_generation_1",
    }],
  };
  const captured = captureRoomExitMembershipGeneration({
    room: initialRoom,
    user,
    expected: "",
  });
  assertEquals(captured, "membership_generation_1");

  const rejoinedRoom = {
    ...initialRoom,
    room_revision: 6,
    players: [{
      ...user,
      membership_id: "membership_generation_2",
    }],
  };
  const stale = assertThrows(
    () =>
      assertExpectedMembershipGeneration({
        room: rejoinedRoom,
        user,
        expected: captured,
      }),
    Error,
  ) as Error & { status?: number; code?: string };
  assertEquals(stale.status, 409);
  assertEquals(stale.code, "room_exit_membership_conflict");
});

Deno.test("legacy exit capture supports players without a persisted membership id", () => {
  const room = {
    id: "room-legacy",
    players: [{ email: "legacy@example.com" }],
  };
  const user = { email: "legacy@example.com" };
  const captured = captureRoomExitMembershipGeneration({
    room,
    user,
    expected: "",
  });
  assertEquals(captured, "legacy_room-legacy_legacy@example.com");
  assertExpectedMembershipGeneration({ room, user, expected: captured });
});

Deno.test("legacy revision is checked before the server captures membership", () => {
  const stale = assertThrows(
    () =>
      captureRoomExitMembershipGeneration({
        room: {
          id: "room-1",
          room_revision: 8,
          players: [{
            user_id: "user-1",
            membership_id: "membership_generation_2",
          }],
        },
        user: { id: "user-1" },
        expected: "",
        expectedRevision: 6,
      }),
    Error,
  ) as Error & { code?: string };
  assertEquals(stale.code, "room_exit_revision_conflict");
});

Deno.test("legacy players receive a stable scoped generation", () => {
  const room = { id: "room-1" };
  const player = { user_id: "user-1", email: "one@example.com" };
  assertEquals(
    playerMembershipGeneration(room, player),
    "legacy_room-1_user-1",
  );
  assertEquals(
    validatedMembershipGeneration("membership_generation_3"),
    "membership_generation_3",
  );
});

Deno.test("legacy expected revision remains a stale-rejoin fallback", () => {
  const error = assertThrows(
    () =>
      assertExpectedMembershipGeneration({
        room: { room_revision: 8 },
        user: {},
        expected: "",
        expectedRevision: 6,
      }),
    Error,
  ) as Error & { code?: string };
  assertEquals(error.code, "room_exit_revision_conflict");
});
