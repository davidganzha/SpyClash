type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function stableUserIDs(room: Entity): string[] {
  const mirrored = Array.isArray(room?.participant_user_ids)
    ? room.participant_user_ids.map(clean)
    : [];
  const players = Array.isArray(room?.players)
    ? room.players.map((player: Entity) => clean(player?.user_id))
    : [];
  return [...new Set([...mirrored, ...players].filter(Boolean))].sort();
}

export function gamePushExpiry(
  room: Entity,
  eventType: "game_started" | "game_finished",
  now = new Date(),
): string {
  if (eventType === "game_finished") {
    return new Date(now.getTime() + 60 * 60 * 1_000).toISOString();
  }
  const startedAt = Date.parse(clean(room.game_started_at));
  const duration = Number(room.game_duration_seconds);
  const timerDeadline = Number.isFinite(startedAt) &&
      Number.isFinite(duration) && duration > 0
    ? startedAt + Math.min(duration, 15 * 60) * 1_000 + 5 * 60 * 1_000
    : now.getTime() + 20 * 60 * 1_000;
  // A queued start alert is useful only around the active match. Never let an
  // offline device receive it hours after the table has already finished.
  return new Date(Math.min(timerDeadline, now.getTime() + 20 * 60 * 1_000))
    .toISOString();
}

export async function enqueueGamePushEvents(input: {
  base44: any;
  room: Entity;
  eventType: "game_started" | "game_finished";
  sourceEventID: string;
  matchID: string;
  actorUserID?: string;
  persist: <T>(writer: () => Promise<T>) => Promise<T>;
  now?: Date;
  randomUUID?: () => string;
}): Promise<void> {
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const store = input.base44.asServiceRole.entities.PushNotificationEvent;
  for (const recipientUserID of stableUserIDs(input.room)) {
    const dedupeKey = [input.eventType, input.sourceEventID, recipientUserID]
      .join(":");
    const existing = await store.filter({ dedupe_key: dedupeKey }) || [];
    if (existing.length) continue;
    await input.persist(() =>
      store.create({
        dedupe_key: dedupeKey,
        source_event_id: clean(input.sourceEventID),
        event_type: input.eventType,
        source_type: "game_room",
        recipient_user_id: recipientUserID,
        actor_user_id: clean(input.actorUserID),
        room_id: clean(input.room.id),
        match_id: clean(input.matchID),
        state: "pending",
        attempt_count: 0,
        delivered_count: 0,
        failed_count: 0,
        delivered_token_hashes: [],
        lease_token: "",
        lease_until: now.toISOString(),
        revision: randomUUID(),
        expires_at: gamePushExpiry(input.room, input.eventType, now),
        created_at: now.toISOString(),
        updated_at: now.toISOString(),
      })
    );
  }
}
