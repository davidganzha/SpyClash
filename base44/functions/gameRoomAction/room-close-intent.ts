type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function unique(values: readonly unknown[]): string[] {
  return [...new Set(values.map(clean).filter(Boolean))];
}

export function exactRoomCloseIntent(room: Entity): Entity | null {
  const intent = room?.close_intent;
  const roomID = clean(room?.id);
  const matchID = clean(room?.match_id);
  if (
    !clean(intent?.id) || !roomID || clean(intent?.room_id) !== roomID ||
    clean(intent?.match_id) !== matchID
  ) return null;
  return intent;
}

export function newRoomCloseIntent(input: {
  room: Entity;
  nextRoomRevision: number;
  participantUserIDs: readonly unknown[];
  randomUUID?: () => string;
  now?: Date;
}): Entity {
  const roomID = clean(input.room?.id);
  if (!roomID) throw new Error("Room id is required for close intent.");
  return {
    id: (input.randomUUID || (() => crypto.randomUUID()))(),
    room_id: roomID,
    // A waiting lobby legitimately has no match identity. Its globally unique
    // room id still binds the closure generation without a sentinel value.
    match_id: clean(input.room?.match_id),
    room_revision: input.nextRoomRevision,
    lobby_revision: Math.max(0, Number(input.room?.lobby_revision || 0)),
    participant_user_ids: [
      ...new Set(input.participantUserIDs.map(clean).filter(Boolean)),
    ],
    created_at: (input.now || new Date()).toISOString(),
  };
}

export function newRoomCloseCompletion(input: {
  room: Entity;
  now?: Date;
}): Entity {
  const intent = exactRoomCloseIntent(input.room);
  if (!intent) throw new Error("An exact room close intent is required.");
  const participantUserIDs = unique(
    Array.isArray(intent.participant_user_ids)
      ? intent.participant_user_ids
      : [],
  );
  const hostEmail = clean(input.room?.host_email).toLocaleLowerCase();
  const players = Array.isArray(input.room?.players) ? input.room.players : [];
  const hostUserID = clean(
    players.find((player: Entity) =>
      clean(player?.email).toLocaleLowerCase() === hostEmail
    )?.user_id,
  );
  if (!hostUserID || !participantUserIDs.includes(hostUserID)) {
    throw new Error("The close completion host identity is missing.");
  }
  return {
    intent_id: clean(intent.id),
    room_id: clean(intent.room_id),
    match_id: clean(intent.match_id),
    host_user_id: hostUserID,
    participant_user_ids: participantUserIDs,
    participant_count: participantUserIDs.length,
    completed_at: (input.now || new Date()).toISOString(),
  };
}

export function roomCloseActivityEndCommitID(
  completion: Entity,
): string {
  const intentID = clean(completion?.intent_id);
  const roomID = clean(completion?.room_id);
  const matchID = clean(completion?.match_id);
  if (!intentID || !roomID) return "";
  return matchID
    ? `room-close:${matchID}:${intentID}`
    : `room-close:no-match:${roomID}:${intentID}`;
}

export function roomCloseCompletionWithActivityEndQueued(input: {
  completion: Entity;
  now?: Date;
}): Entity {
  const commitID = roomCloseActivityEndCommitID(input.completion);
  if (!commitID) throw new Error("An exact room close completion is required.");
  return {
    ...input.completion,
    activity_end_queued: true,
    activity_end_commit_id: commitID,
    activity_end_queued_at: (input.now || new Date()).toISOString(),
  };
}

export function roomCloseActivityEndIsQueued(completion: Entity): boolean {
  const queuedAt = Date.parse(clean(completion?.activity_end_queued_at));
  return completion?.activity_end_queued === true &&
    clean(completion?.activity_end_commit_id) ===
      roomCloseActivityEndCommitID(completion) &&
    Number.isFinite(queuedAt);
}

export function exactRoomCloseCompletion(
  signal: Entity,
  expectedRoomIDValue?: unknown,
  expectedUserIDValue?: unknown,
): Entity | null {
  const completion = signal?.close_completion;
  const roomID = clean(expectedRoomIDValue || signal?.room_id);
  const expectedUserID = clean(expectedUserIDValue);
  const participantUserIDs = unique(
    Array.isArray(completion?.participant_user_ids)
      ? completion.participant_user_ids
      : [],
  );
  const completedAt = Date.parse(clean(completion?.completed_at));
  if (
    clean(signal?.state) !== "closed" || !roomID ||
    clean(signal?.room_id) !== roomID ||
    clean(signal?.close_intent_id) !== clean(completion?.intent_id) ||
    clean(signal?.close_match_id) !== clean(completion?.match_id) ||
    clean(completion?.room_id) !== roomID ||
    !clean(completion?.intent_id) || !clean(completion?.host_user_id) ||
    participantUserIDs.length === 0 ||
    Number(completion?.participant_count) !== participantUserIDs.length ||
    !participantUserIDs.includes(clean(signal?.user_id)) ||
    !participantUserIDs.includes(clean(completion?.host_user_id)) ||
    !Number.isFinite(completedAt) ||
    (expectedUserID && clean(signal?.user_id) !== expectedUserID)
  ) return null;
  return {
    ...completion,
    participant_user_ids: participantUserIDs,
  };
}

export function roomCloseCompletionCoversSignals(
  signals: readonly Entity[],
  completion: Entity,
): boolean {
  const participantUserIDs = unique(completion?.participant_user_ids || []);
  return participantUserIDs.length > 0 &&
    participantUserIDs.every((userID) =>
      signals.some((signal) => {
        const exact = exactRoomCloseCompletion(
          signal,
          completion?.room_id,
          userID,
        );
        return clean(exact?.intent_id) === clean(completion?.intent_id) &&
          clean(exact?.host_user_id) === clean(completion?.host_user_id) &&
          JSON.stringify(exact?.participant_user_ids) ===
            JSON.stringify(participantUserIDs);
      })
    );
}

/**
 * A caller may use this only after `roomCloseCompletionCoversSignals` proved
 * the exact participant-wide tombstone. At that point an eventually
 * consistent GameRoom read from before the intent was written cannot revoke
 * the durable close authorization; it only has to belong to the same id.
 */
export function verifiedRoomCloseCompletionDominatesSnapshot(
  completion: Entity,
  room: Entity | null | undefined,
): boolean {
  const roomID = clean(completion?.room_id);
  return Boolean(roomID) && (!room || clean(room?.id) === roomID);
}
