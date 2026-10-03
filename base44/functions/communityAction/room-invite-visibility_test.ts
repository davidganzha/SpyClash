import { assertEquals } from "jsr:@std/assert@1";
import {
  actionableRoomInvites,
  roomInviteIsActionable,
} from "./room-invite-visibility.ts";

const now = new Date("2026-10-03T12:00:00.000Z");
const invitation = {
  id: "invite",
  room_id: "room",
  recipient_user_id: "guest",
  status: "pending",
  created_at: "2026-10-03T11:00:00.000Z",
};
const waiting = {
  id: "room",
  status: "waiting",
  players: [{ user_id: "host" }],
};

Deno.test("invitation attention resolves after code/QR join or terminal room change", () => {
  assertEquals(roomInviteIsActionable(invitation, waiting, "guest", now), true);
  assertEquals(
    roomInviteIsActionable(
      { ...invitation, status: "accepted" },
      waiting,
      "guest",
      now,
    ),
    true,
  );
  for (
    const room of [null, { ...waiting, close_intent: {} }, {
      ...waiting,
      status: "playing",
    }, { ...waiting, players: [{ user_id: "guest" }] }]
  ) {
    assertEquals(roomInviteIsActionable(invitation, room, "guest", now), false);
  }
  for (const status of ["declined", "expired"]) {
    assertEquals(
      roomInviteIsActionable({ ...invitation, status }, waiting, "guest", now),
      false,
    );
  }
  assertEquals(
    roomInviteIsActionable(invitation, waiting, "other", now),
    false,
  );
  assertEquals(
    roomInviteIsActionable(
      { ...invitation, created_at: "2026-10-02T12:00:00.000Z" },
      waiting,
      "guest",
      now,
    ),
    false,
  );
  assertEquals(
    roomInviteIsActionable(
      invitation,
      { ...waiting, players: [{ email: "Guest@Example.com" }] },
      "guest",
      now,
      "guest@example.com",
    ),
    false,
  );
});

Deno.test("attention batches room reads and ignores unrelated room identities", async () => {
  let calls = 0;
  const invitations = Array.from(
    { length: 75 },
    (_, index) => ({ ...invitation, id: `invite-${index}` }),
  );
  const visible = await actionableRoomInvites({
    invitations,
    userID: "guest",
    now,
    roomStore: {
      filter: async () => {
        calls += 1;
        return [waiting];
      },
    },
  });
  assertEquals(visible.length, 75);
  assertEquals(calls, 1);
});

Deno.test("Inbox and Community share identical room invitation visibility", async () => {
  assertEquals(
    await Deno.readTextFile(
      new URL("./room-invite-visibility.ts", import.meta.url),
    ),
    await Deno.readTextFile(
      new URL(
        "../notificationAction/room-invite-visibility.ts",
        import.meta.url,
      ),
    ),
  );
});
