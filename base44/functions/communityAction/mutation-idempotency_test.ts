import { assertEquals } from "jsr:@std/assert@1";
import {
  friendshipDecisionDisposition,
  roomInviteAcceptanceDisposition,
} from "./mutation-idempotency.ts";

Deno.test("friendship accept and decline replay only for the original addressee", () => {
  const incoming = {
    requester_id: "requester",
    addressee_id: "addressee",
    status: "pending",
  };

  assertEquals(
    friendshipDecisionDisposition("accept", incoming, "addressee"),
    "apply",
  );
  assertEquals(
    friendshipDecisionDisposition(
      "accept",
      { ...incoming, status: "accepted" },
      "addressee",
    ),
    "already_applied",
  );
  assertEquals(
    friendshipDecisionDisposition(
      "decline",
      { ...incoming, status: "declined" },
      "addressee",
    ),
    "already_applied",
  );
  assertEquals(
    friendshipDecisionDisposition(
      "accept",
      { ...incoming, status: "accepted" },
      "requester",
    ),
    "invalid_actor",
  );
  assertEquals(
    friendshipDecisionDisposition(
      "accept",
      { ...incoming, status: "declined" },
      "addressee",
    ),
    "invalid_state",
  );
});

Deno.test("room invite accept replay is scoped to the original recipient", () => {
  const invite = {
    sender_user_id: "sender",
    recipient_user_id: "recipient",
    status: "pending",
  };

  assertEquals(
    roomInviteAcceptanceDisposition(invite, "recipient"),
    "apply",
  );
  assertEquals(
    roomInviteAcceptanceDisposition(
      { ...invite, status: "accepted" },
      "recipient",
    ),
    "already_applied",
  );
  assertEquals(
    roomInviteAcceptanceDisposition(
      { ...invite, status: "accepted" },
      "sender",
    ),
    "invalid_actor",
  );
  assertEquals(
    roomInviteAcceptanceDisposition(
      { ...invite, status: "expired" },
      "recipient",
    ),
    "invalid_state",
  );
});

Deno.test("community main keeps missing decline and consume cleanup idempotent", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  const inviteActions = source.slice(
    source.indexOf('if (\n      ["accept_room_invite"'),
    source.indexOf('if (action === "block")'),
  );
  assertEquals(
    inviteActions.includes('if (action === "accept_room_invite")'),
    true,
  );
  assertEquals(
    inviteActions.includes('if (action !== "consume_room_invite")'),
    false,
  );
});
