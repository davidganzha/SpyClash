type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function uniqueSorted(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))].sort();
}

function rawTerminalIntent(room: Entity): Entity | null {
  const intent = room?.terminal_intent;
  return intent && typeof intent === "object" && !Array.isArray(intent)
    ? intent
    : null;
}

function expectedFinishedEventID(matchID: string): string {
  return matchID ? `game-finished:${matchID}` : "";
}

export function terminalOutboxCommitRecipientUserIDs(room: Entity): string[] {
  return uniqueSorted([
    ...(Array.isArray(room?.participant_user_ids)
      ? room.participant_user_ids
      : []),
    ...(Array.isArray(room?.players)
      ? room.players.map((player: Entity) => player?.user_id)
      : []),
  ]);
}

export function terminalOutboxCommitIsProven(room: Entity): boolean {
  const intent = rawTerminalIntent(room);
  const receipt = intent?.game_finished_outbox_commit;
  const matchID = clean(intent?.match_id);
  const sourceEventID = clean(room?.game_finished_event_id);
  const recipientUserIDs = uniqueSorted(
    Array.isArray(receipt?.recipient_user_ids)
      ? receipt.recipient_user_ids
      : [],
  );
  const committedAt = Date.parse(clean(receipt?.committed_at));
  return clean(room?.status).toLocaleLowerCase() === "finished" &&
    Boolean(matchID) && clean(room?.match_id) === matchID &&
    sourceEventID === expectedFinishedEventID(matchID) &&
    clean(receipt?.source_event_id) === sourceEventID &&
    clean(receipt?.match_id) === matchID &&
    recipientUserIDs.length > 0 &&
    Number(receipt?.recipient_count) === recipientUserIDs.length &&
    JSON.stringify(receipt?.recipient_user_ids) ===
      JSON.stringify(recipientUserIDs) &&
    Number.isFinite(committedAt);
}

export function terminalOutboxCommitPatch(input: {
  room: Entity;
  recipientUserIDs: readonly unknown[];
  committedAt?: Date;
}): Entity {
  const intent = rawTerminalIntent(input.room);
  const matchID = clean(intent?.match_id);
  const sourceEventID = clean(input.room?.game_finished_event_id);
  const recipientUserIDs = uniqueSorted(input.recipientUserIDs);
  const committedAt = input.committedAt || new Date();
  if (
    !intent || clean(input.room?.status).toLocaleLowerCase() !== "finished" ||
    !matchID || clean(input.room?.match_id) !== matchID ||
    sourceEventID !== expectedFinishedEventID(matchID) ||
    !recipientUserIDs.length || !Number.isFinite(committedAt.getTime())
  ) {
    throw Object.assign(
      new Error("The complete game-finished outbox cannot be certified."),
      { status: 503, code: "terminal_outbox_unconfirmed", retryable: true },
    );
  }
  return {
    terminal_intent: {
      ...intent,
      game_finished_outbox_commit: {
        source_event_id: sourceEventID,
        match_id: matchID,
        recipient_user_ids: recipientUserIDs,
        recipient_count: recipientUserIDs.length,
        committed_at: committedAt.toISOString(),
      },
    },
  };
}

export function assertTerminalOutboxCommitBeforeAuthorityReset(
  room: Entity,
): void {
  if (!rawTerminalIntent(room) || terminalOutboxCommitIsProven(room)) return;
  throw Object.assign(
    new Error(
      "The finished result is still reconciling its complete notification outbox.",
    ),
    { status: 503, code: "terminal_outbox_unconfirmed", retryable: true },
  );
}
