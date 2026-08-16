import { assertEquals } from "jsr:@std/assert@1";
import {
  committedPersonalInboxPatch,
  isPersonalInboxEvent,
} from "./inbox-projection.ts";

Deno.test("transient game lifecycle alerts remain push-only", () => {
  assertEquals(isPersonalInboxEvent({ event_type: "friend_request" }), true);
  assertEquals(isPersonalInboxEvent({ event_type: "room_invite" }), true);
  assertEquals(isPersonalInboxEvent({ event_type: "game_started" }), false);
  assertEquals(isPersonalInboxEvent({ event_type: "game_finished" }), false);
});

Deno.test("committed personal inbox projection never stores an unsafe actor name", () => {
  const patch = committedPersonalInboxPatch(
    {
      event_type: "room_invite",
      source_event_id: "unsafe-invite",
      created_at: "2026-08-16T10:00:00.000Z",
    },
    { valid: true, actorName: "za|upa" },
    new Date("2026-08-16T10:00:01.000Z"),
  );
  assertEquals(
    patch.inbox_body_en,
    "An operative invited you to a SpyClash room.",
  );
  assertEquals(
    patch.inbox_body_ru,
    "Оперативник приглашает вас в комнату SpyClash.",
  );
  assertEquals(
    patch.inbox_body_es,
    "Un agente te invitó a una sala de SpyClash.",
  );
  assertEquals(
    patch.inbox_body_uk,
    "Оперативник запрошує вас до кімнати SpyClash.",
  );
  assertEquals(JSON.stringify(patch).includes("za|upa"), false);

  const safePatch = committedPersonalInboxPatch(
    {
      event_type: "friend_request",
      source_event_id: "safe-request",
      created_at: "2026-08-16T10:00:00.000Z",
    },
    { valid: true, actorName: "Pizza Lupin" },
    new Date("2026-08-16T10:00:01.000Z"),
  );
  assertEquals(safePatch.inbox_body_en, "Pizza Lupin wants to connect.");
});
