import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  replayEligibility,
  replayResetMembershipPatch,
  replayVoteState,
  replayVoteTransition,
} from "./replay-policy.ts";

function room(overrides: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    status: "finished",
    host_email: "a@example.com",
    players: [
      { user_id: "user-a", email: "a@example.com", name: "A" },
      { user_id: "user-b", email: "b@example.com", name: "B" },
      { user_id: "user-c", email: "c@example.com", name: "C" },
    ],
    participant_user_ids: ["user-a", "user-b", "user-c"],
    departed_player_emails: [],
    ready_players: [],
    ...overrides,
  };
}

Deno.test("replay eligibility excludes tombstones and duplicate aliases", () => {
  const eligibility = replayEligibility(room({
    departed_player_emails: [" C@EXAMPLE.COM "],
    players: [
      { user_id: "user-a", email: "a@example.com" },
      { user_id: "user-b", email: "b@example.com" },
      { user_id: "user-b", email: "alias@example.com" },
      { user_id: "user-c", email: "c@example.com" },
    ],
  }));
  assertEquals(eligibility.emails, ["a@example.com", "b@example.com"]);
  assertEquals(eligibility.userIDs, ["user-a", "user-b"]);
  assertEquals(eligibility.removedUserIDs, ["user-c"]);
});

Deno.test("departure then finish reaches unanimous replay without the departed player", () => {
  const departedFinished = room({
    departed_player_emails: ["c@example.com"],
    ready_players: ["a@example.com", "c@example.com", "A@example.com"],
  });
  const transition = replayVoteTransition(
    departedFinished,
    " B@EXAMPLE.COM ",
  );
  assertEquals(transition.eligibleEmails, [
    "a@example.com",
    "b@example.com",
  ]);
  assertEquals(transition.votes, ["a@example.com", "b@example.com"]);
  assertEquals(transition.patch, {
    ready_players: ["a@example.com", "b@example.com"],
  });
  assertEquals(transition.unanimous, true);

  const reset = replayResetMembershipPatch({
    ...departedFinished,
    ...transition.patch,
  });
  assertEquals(
    reset.players.map((player: Record<string, unknown>) => player.email),
    ["a@example.com", "b@example.com"],
  );
  assertEquals(reset.participant_user_ids, ["user-a", "user-b"]);
  assertEquals(reset.host_email, "a@example.com");
  assertEquals(reset.departed_player_emails, []);
});

Deno.test("departed player cannot replay vote and nonterminal status fails closed", () => {
  const departed = assertThrows(() =>
    replayVoteTransition(
      room({ departed_player_emails: ["c@example.com"] }),
      "c@example.com",
    )
  ) as Error & { status?: number; code?: string };
  assertEquals(departed.status, 403);
  assertEquals(departed.code, "room_access_revoked");

  const active = assertThrows(() =>
    replayVoteTransition(room({ status: "playing" }), "a@example.com")
  ) as Error & { status?: number; code?: string };
  assertEquals(active.status, 409);
  assertEquals(active.code, "replay_vote_inactive");
});

Deno.test("legacy replay roster keeps stable participant index without email inference", () => {
  const reset = replayResetMembershipPatch(room({
    players: [
      { user_id: "user-a", email: "a@example.com" },
      { email: "legacy@example.com" },
      { user_id: "user-c", email: "c@example.com" },
    ],
    participant_user_ids: ["user-a", "legacy-index", "user-c"],
    departed_player_emails: ["c@example.com"],
  }));
  assertEquals(reset.participant_user_ids, ["user-a", "legacy-index"]);
  assertEquals(
    reset.players.map((player: Record<string, unknown>) => player.email),
    ["a@example.com", "legacy@example.com"],
  );
});

Deno.test("replay reset readiness is server-owned and requires every eligible vote", () => {
  assertEquals(
    replayVoteState(room({
      ready_players: ["a@example.com", "b@example.com"],
    })).unanimous,
    false,
  );
  assertEquals(
    replayVoteState(room({
      departed_player_emails: ["c@example.com"],
      ready_players: ["A@example.com", "b@example.com", "c@example.com"],
    })),
    {
      votes: ["a@example.com", "b@example.com"],
      eligibleEmails: ["a@example.com", "b@example.com"],
      unanimous: true,
    },
  );
});
