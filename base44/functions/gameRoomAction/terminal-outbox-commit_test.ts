import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertTerminalOutboxCommitBeforeAuthorityReset,
  terminalOutboxCommitIsProven,
  terminalOutboxCommitPatch,
  terminalOutboxCommitRecipientUserIDs,
} from "./terminal-outbox-commit.ts";

function finishedRoom(overrides: Record<string, unknown> = {}) {
  return {
    id: "room-1",
    status: "finished",
    match_id: "match-1",
    game_finished_event_id: "game-finished:match-1",
    terminal_intent: {
      match_id: "match-1",
      winner: "detectives",
      decided_at: "2026-09-01T12:00:00.000Z",
    },
    participant_user_ids: ["user-c", "user-a"],
    players: [{ user_id: "user-b" }, { user_id: "user-a" }],
    ...overrides,
  };
}

Deno.test("terminal outbox receipt proves the exact full fanout before authority reset", () => {
  const room = finishedRoom();
  const recipients = terminalOutboxCommitRecipientUserIDs(room);
  assertEquals(recipients, ["user-a", "user-b", "user-c"]);
  assertEquals(terminalOutboxCommitIsProven(room), false);
  const error = assertThrows(
    () => assertTerminalOutboxCommitBeforeAuthorityReset(room),
  ) as Error & { code?: string; retryable?: boolean };
  assertEquals(error.code, "terminal_outbox_unconfirmed");
  assertEquals(error.retryable, true);

  const committed = {
    ...room,
    ...terminalOutboxCommitPatch({
      room,
      recipientUserIDs: recipients,
      committedAt: new Date("2026-09-01T12:00:05.000Z"),
    }),
  };
  assertEquals(terminalOutboxCommitIsProven(committed), true);
  assertTerminalOutboxCommitBeforeAuthorityReset(committed);

  // Once the server certifies the original full topology, a later permitted
  // guest departure must not invalidate that durable proof.
  const afterDeparture = {
    ...committed,
    participant_user_ids: ["user-a", "user-c"],
    players: [{ user_id: "user-a" }, { user_id: "user-c" }],
  };
  assertEquals(terminalOutboxCommitIsProven(afterDeparture), true);
});

Deno.test("terminal outbox proof fails closed for partial or cross-match receipts", () => {
  const room = finishedRoom();
  const baseReceipt = terminalOutboxCommitPatch({
    room,
    recipientUserIDs: ["user-a", "user-b", "user-c"],
    committedAt: new Date("2026-09-01T12:00:05.000Z"),
  }).terminal_intent.game_finished_outbox_commit;
  for (
    const receipt of [
      { ...baseReceipt, recipient_user_ids: ["user-a", "user-b"] },
      { ...baseReceipt, recipient_count: 2 },
      { ...baseReceipt, match_id: "older-match" },
      { ...baseReceipt, source_event_id: "game-finished:older-match" },
      { ...baseReceipt, committed_at: "invalid" },
    ]
  ) {
    assertEquals(
      terminalOutboxCommitIsProven({
        ...room,
        terminal_intent: {
          ...room.terminal_intent,
          game_finished_outbox_commit: receipt,
        },
      }),
      false,
    );
  }
});
