import { assertEquals } from "jsr:@std/assert@1";
import {
  exactRoomCloseCompletion,
  exactRoomCloseIntent,
  newRoomCloseCompletion,
  newRoomCloseIntent,
  roomCloseActivityEndCommitID,
  roomCloseActivityEndIsQueued,
  roomCloseCompletionCoversSignals,
  roomCloseCompletionWithActivityEndQueued,
  verifiedRoomCloseCompletionDominatesSnapshot,
} from "./room-close-intent.ts";

Deno.test("host can commit a close intent before the first match exists", () => {
  const room = {
    id: "lobby-1",
    status: "waiting",
    room_revision: 4,
    lobby_revision: 2,
  };
  const closeIntent = newRoomCloseIntent({
    room,
    nextRoomRevision: 5,
    participantUserIDs: ["host-user", "guest-user", "host-user"],
    randomUUID: () => "close-lobby-1",
    now: new Date("2026-09-01T12:00:00.000Z"),
  });

  assertEquals(closeIntent, {
    id: "close-lobby-1",
    room_id: "lobby-1",
    match_id: "",
    room_revision: 5,
    lobby_revision: 2,
    participant_user_ids: ["host-user", "guest-user"],
    created_at: "2026-09-01T12:00:00.000Z",
  });
  assertEquals(
    exactRoomCloseIntent({ ...room, close_intent: closeIntent }),
    closeIntent,
  );
});

Deno.test("sole-player waiting-room deletion uses the room id as closure identity", () => {
  const room = { id: "solo-lobby", status: "waiting", room_revision: 0 };
  const closeIntent = newRoomCloseIntent({
    room,
    nextRoomRevision: 1,
    participantUserIDs: ["only-player"],
    randomUUID: () => "close-solo",
    now: new Date("2026-09-01T12:00:00.000Z"),
  });
  assertEquals(closeIntent.match_id, "");
  assertEquals(closeIntent.participant_user_ids, ["only-player"]);
  assertEquals(
    exactRoomCloseIntent({ ...room, close_intent: closeIntent })?.id,
    "close-solo",
  );
});

Deno.test("a receipt from another match is never accepted", () => {
  assertEquals(
    exactRoomCloseIntent({
      id: "room-1",
      match_id: "match-new",
      close_intent: {
        id: "close-old",
        room_id: "room-1",
        match_id: "match-old",
      },
    }),
    null,
  );
});

Deno.test("full-fanout completion binds the host and exact participant set", () => {
  const room = {
    id: "room-1",
    match_id: "match-1",
    host_email: "host@example.com",
    players: [
      { email: "host@example.com", user_id: "host-user" },
      { email: "guest@example.com", user_id: "guest-user" },
    ],
    close_intent: {
      id: "close-1",
      room_id: "room-1",
      match_id: "match-1",
      participant_user_ids: ["host-user", "guest-user", "host-user"],
    },
  };
  const completion = newRoomCloseCompletion({
    room,
    now: new Date("2026-09-01T12:01:00.000Z"),
  });
  assertEquals(completion, {
    intent_id: "close-1",
    room_id: "room-1",
    match_id: "match-1",
    host_user_id: "host-user",
    participant_user_ids: ["host-user", "guest-user"],
    participant_count: 2,
    completed_at: "2026-09-01T12:01:00.000Z",
  });
  const signals = ["host-user", "guest-user"].map((userID) => ({
    user_id: userID,
    room_id: "room-1",
    state: "closed",
    close_intent_id: "close-1",
    close_match_id: "match-1",
    close_completion: completion,
  }));
  assertEquals(
    exactRoomCloseCompletion(signals[0], "room-1", "host-user"),
    completion,
  );
  assertEquals(roomCloseCompletionCoversSignals(signals, completion), true);
  assertEquals(
    roomCloseCompletionCoversSignals(signals.slice(0, 1), completion),
    false,
  );
  const queued = roomCloseCompletionWithActivityEndQueued({
    completion,
    now: new Date("2026-09-01T12:02:00.000Z"),
  });
  assertEquals(
    roomCloseActivityEndCommitID(queued),
    "room-close:match-1:close-1",
  );
  assertEquals(roomCloseActivityEndIsQueued(queued), true);
  assertEquals(
    roomCloseActivityEndIsQueued({
      ...queued,
      activity_end_commit_id: "room-close:match-old:close-1",
    }),
    false,
  );
});

Deno.test("a partial close receipt is not a full-fanout completion", () => {
  assertEquals(
    exactRoomCloseCompletion({
      user_id: "host-user",
      room_id: "room-1",
      state: "closed",
      close_intent_id: "close-1",
      close_match_id: "match-1",
    }),
    null,
  );
});

Deno.test("verified full fanout dominates a stale pre-intent room snapshot", () => {
  const completion = {
    intent_id: "close-1",
    room_id: "room-1",
    match_id: "match-1",
    host_user_id: "host-user",
    participant_user_ids: ["host-user", "guest-user"],
    participant_count: 2,
    completed_at: "2026-09-01T12:01:00.000Z",
  };
  assertEquals(
    verifiedRoomCloseCompletionDominatesSnapshot(completion, {
      id: "room-1",
      match_id: "match-1",
      room_revision: 20,
      close_intent: null,
    }),
    true,
  );
  assertEquals(
    verifiedRoomCloseCompletionDominatesSnapshot(completion, {
      id: "room-1",
      match_id: "older-match",
      close_intent: { id: "older-intent" },
    }),
    true,
  );
  assertEquals(
    verifiedRoomCloseCompletionDominatesSnapshot(completion, {
      id: "another-room",
    }),
    false,
  );
});
