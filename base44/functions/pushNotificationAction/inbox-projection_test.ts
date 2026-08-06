import { assertEquals } from "jsr:@std/assert@1";
import { isPersonalInboxEvent } from "./inbox-projection.ts";

Deno.test("transient game lifecycle alerts remain push-only", () => {
  assertEquals(isPersonalInboxEvent({ event_type: "friend_request" }), true);
  assertEquals(isPersonalInboxEvent({ event_type: "room_invite" }), true);
  assertEquals(isPersonalInboxEvent({ event_type: "game_started" }), false);
  assertEquals(isPersonalInboxEvent({ event_type: "game_finished" }), false);
});
