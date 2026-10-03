import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { resolveRoomInvitesAfterJoin } from "./room-invite-resolution.ts";
import { roomInviteIsActionable } from "../communityAction/room-invite-visibility.ts";

type Row = Record<string, any>;
function storeWith(rows: Row[]) {
  return {
    records: rows,
    writes: 0,
    async updateMany(query: Row, update: Row) {
      this.writes += 1;
      let updated = 0;
      for (const row of rows) {
        if (
          row.recipient_user_id !== query.recipient_user_id ||
          row.room_id !== query.room_id ||
          !query.status.$in.includes(row.status)
        ) continue;
        Object.assign(row, update.$set);
        updated += 1;
      }
      return { updated };
    },
    async filter(query: Row) {
      return rows.filter((row) =>
        row.recipient_user_id === query.recipient_user_id &&
        row.room_id === query.room_id && query.status.$in.includes(row.status)
      );
    },
  };
}

const joinedRoom = {
  id: "room",
  status: "waiting",
  players: [{ user_id: "guest", email: "guest@example.com" }],
};
function input(store: ReturnType<typeof storeWith>) {
  return {
    store,
    room: joinedRoom,
    userID: "guest",
    userEmail: "guest@example.com",
    assertActorLease: async () => {},
    now: new Date("2026-10-03T12:00:00.000Z"),
  };
}

Deno.test("code/QR join resolves every inviter without touching another recipient or room", async () => {
  const store = storeWith([
    {
      id: "one",
      recipient_user_id: "guest",
      room_id: "room",
      status: "pending",
    },
    {
      id: "two",
      recipient_user_id: "guest",
      room_id: "room",
      status: "accepted",
    },
    {
      id: "other-user",
      recipient_user_id: "other",
      room_id: "room",
      status: "pending",
    },
    {
      id: "other-room",
      recipient_user_id: "guest",
      room_id: "elsewhere",
      status: "pending",
    },
  ]);
  await resolveRoomInvitesAfterJoin(input(store));
  assertEquals(store.records.map((row) => row.status), [
    "expired",
    "expired",
    "pending",
    "pending",
  ]);
  // Leaving and replaying the same join cannot resurrect a resolved invite.
  assertEquals(
    roomInviteIsActionable(
      store.records[0],
      { ...joinedRoom, players: [] },
      "guest",
    ),
    false,
  );
  await resolveRoomInvitesAfterJoin(input(store));
  assertEquals(store.records.map((row) => row.status), [
    "expired",
    "expired",
    "pending",
    "pending",
  ]);
});

Deno.test("join invite resolution reconciles a lost successful write response", async () => {
  const store = storeWith([{
    recipient_user_id: "guest",
    room_id: "room",
    status: "pending",
  }]);
  const update = store.updateMany.bind(store);
  store.updateMany = async (query, patch) => {
    await update(query, patch);
    throw new Error("response lost");
  };
  await resolveRoomInvitesAfterJoin(input(store));
  assertEquals(store.records[0].status, "expired");
});

Deno.test("failed persistence or an expired lifecycle lease never claims cleanup success", async () => {
  const store = storeWith([{
    recipient_user_id: "guest",
    room_id: "room",
    status: "pending",
  }]);
  await assertRejects(
    () =>
      resolveRoomInvitesAfterJoin({
        ...input(store),
        assertActorLease: () => Promise.reject(new Error("lease expired")),
      }),
    Error,
    "lease expired",
  );
  assertEquals(store.writes, 0);
  store.updateMany = () => Promise.reject(new Error("write unavailable"));
  await assertRejects(
    () => resolveRoomInvitesAfterJoin(input(store)),
    Error,
    "write unavailable",
  );
  assertEquals(store.records[0].status, "pending");
  await assertRejects(
    () =>
      resolveRoomInvitesAfterJoin({
        ...input(store),
        room: { ...joinedRoom, players: [] },
      }),
    Error,
    "confirmed membership",
  );
});

Deno.test("join integration resolves invitations only after confirmed CAS, including replay", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const join = source.slice(
    source.indexOf("async function joinRoom("),
    source.indexOf("async function beginReadyCheck("),
  );
  assertEquals(
    join.includes("const joinedRoom = await updateRoomWithRetry("),
    true,
  );
  assertEquals(join.includes("await resolveRoomInvitesAfterJoin({"), true);
  assertEquals(
    /assertActorLease:\s*\(\)\s*=>\s*assertRoomHistoryPersistenceBoundary\(base44, user\.id\)/
      .test(join),
    true,
  );
  assertEquals(
    join.indexOf("await resolveRoomInvitesAfterJoin({") >
      join.indexOf("const joinedRoom = await updateRoomWithRetry("),
    true,
  );
  assertEquals(join.includes("return joinedRoom;"), true);
});
