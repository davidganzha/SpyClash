import { assertEquals } from "jsr:@std/assert@1";
import {
  contentStateForUser,
  liveActivityPayload,
  liveActivityTerminationPayload,
  sendLiveActivityUpdate,
} from "./live-activity.ts";

const room = {
  id: "room-1",
  match_id: "provider-match-1",
  status: "playing",
  game_mode: "questions",
  players: [
    {
      user_id: "detective-id",
      email: "Detective@Example.com",
      name: "Raven",
      avatar: "🦅",
    },
    {
      user_id: "spy-id",
      email: "spy@example.com",
      name: "Shade",
      avatar: "🎭",
    },
  ],
  participant_user_ids: ["detective-id", "spy-id"],
  spy_email: "spy@example.com",
  word: "Embassy",
  current_asker_email: "Detective@Example.com",
  current_answerer_email: "spy@example.com",
  round_number: 2,
  game_started_at: "2026-07-15T12:00:00.000Z",
  game_duration_seconds: 900,
  cards_read: ["Detective@Example.com", "spy@example.com"],
  updated_date: "2026-07-15T12:01:00.000Z",
};

Deno.test("Live Activity uses opaque player ids and never exports private intel", async () => {
  const result = await contentStateForUser(room, "detective-id");
  assertEquals(result?.viewerPlayerID, "1452b3948c5de92cbeedb449");
  assertEquals(result?.state.privateIntel, null);
  assertEquals(result?.state.timerEndsAtEpochSeconds, 1784117700);
  assertEquals(result?.state.currentSpeakerID, result?.state.currentAskerID);
  assertEquals(JSON.stringify(result?.state).includes("@example.com"), false);
});

Deno.test("spy Activity also receives no private role payload", async () => {
  const result = await contentStateForUser(room, "spy-id");
  assertEquals(result?.state.privateIntel, null);
});

Deno.test("private role and word stay off the Lock Screen until this player reads the card", async () => {
  const result = await contentStateForUser(
    { ...room, cards_read: ["spy@example.com"] },
    "detective-id",
  );
  assertEquals(result?.state.privateIntel, null);
});

Deno.test("mixed-case spectator identity receives no private data", async () => {
  const result = await contentStateForUser({
    ...room,
    spectators: ["DETECTIVE@example.COM"],
  }, "detective-id");
  assertEquals(result?.state.privateIntel, null);
});

Deno.test("running Live Activity deadline includes accumulated pause time", async () => {
  const result = await contentStateForUser({
    ...room,
    game_paused_total_seconds: 45,
  }, "detective-id");
  assertEquals(result?.state.timerEndsAtEpochSeconds, 1784117745);
  assertEquals(result?.state.pausedSecondsRemaining, null);
});

Deno.test("paused Live Activity freezes the remaining duration", async () => {
  const result = await contentStateForUser({
    ...room,
    game_paused_at: "2026-07-15T12:03:00.000Z",
    game_paused_total_seconds: 30,
  }, "detective-id");
  assertEquals(result?.state.timerEndsAtEpochSeconds, null);
  assertEquals(result?.state.pausedSecondsRemaining, 750);
});

Deno.test("Live Activity voting phase uses the same 51 percent active-player threshold", async () => {
  const below = await contentStateForUser({
    ...room,
    players: [...room.players, {
      user_id: "third-id",
      email: "third@example.com",
      name: "Third",
    }],
    participant_user_ids: [...room.participant_user_ids, "third-id"],
    vote_requests: ["spy@example.com"],
  }, "detective-id");
  assertEquals(below?.state.phase, "playing");
  const active = await contentStateForUser({
    ...room,
    players: [...room.players, {
      user_id: "third-id",
      email: "third@example.com",
      name: "Third",
    }],
    participant_user_ids: [...room.participant_user_ids, "third-id"],
    vote_requests: ["spy@example.com", "third@example.com"],
  }, "detective-id");
  assertEquals(active?.state.phase, "voting");
});

Deno.test("ActivityKit push-to-start attributes bind room and current match generation", async () => {
  const built = await liveActivityPayload({
    room,
    registration: { user_id: "detective-id", token_kind: "push_to_start" },
    now: new Date("2026-07-15T12:01:00.000Z"),
  });
  const aps = built?.payload.aps;
  assertEquals(aps.event, "start");
  assertEquals(aps.attributes.roomID, "room-1");
  assertEquals(aps.attributes.matchID, "provider-match-1");
  assertEquals(aps["stale-date"], 1784117760);
  assertEquals(aps["attributes-type"], "SpyClashMatchActivityAttributes");
});

Deno.test("push-to-start dedupe ledger supports multiple concurrent match ids", async () => {
  const skipped = await sendLiveActivityUpdate({
    room,
    registration: {
      user_id: "detective-id",
      token_kind: "push_to_start",
      started_match_ids: ["another-match", "provider-match-1"],
    },
  });
  assertEquals(skipped.skipped, true);
  assertEquals(skipped.reason, "already_started");
});

Deno.test("generic remote end survives room deletion without leaking room data", () => {
  const payload = liveActivityTerminationPayload({
    revision: 42,
    now: new Date("2026-07-26T12:00:00.000Z"),
  });
  assertEquals(payload.aps.event, "end");
  assertEquals(payload.aps["content-state"].phase, "completed");
  assertEquals(payload.aps["content-state"].participants, []);
  assertEquals(payload.aps["content-state"].revision, 42);
  assertEquals(
    payload.aps["dismissal-date"],
    payload.aps.timestamp + 300,
  );
  assertEquals(JSON.stringify(payload).includes("email"), false);
});
