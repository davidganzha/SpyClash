import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

function stableParticipantUserIDs(room: Entity): string[] {
  const mirrored = Array.isArray(room?.participant_user_ids)
    ? room.participant_user_ids.map(clean)
    : [];
  const players = Array.isArray(room?.players)
    ? room.players.map((player: Entity) => clean(player?.user_id))
    : [];
  return [...new Set([...mirrored, ...players].filter(Boolean))].sort();
}

function startExpiry(room: Entity, now: Date): string {
  const reference = Date.parse(clean(
    room.game_started_at || room.intro_started_at || room.updated_date ||
      room.created_date,
  ));
  const duration = Number(room.game_duration_seconds);
  const completedPause = Math.max(
    0,
    Number.isFinite(Number(room.game_paused_total_seconds))
      ? Number(room.game_paused_total_seconds)
      : 0,
  );
  const activePauseStarted = Date.parse(clean(room.game_paused_at));
  const activePause = Number.isFinite(activePauseStarted)
    ? Math.max(0, Math.floor((now.getTime() - activePauseStarted) / 1_000))
    : 0;
  const deadline = Number.isFinite(reference) && Number.isFinite(duration) &&
      duration > 0
    ? reference +
      (Math.min(duration, 15 * 60) + completedPause + activePause + 5 * 60) *
        1_000
    : now.getTime() + 20 * 60 * 1_000;
  return new Date(Math.min(deadline, now.getTime() + 20 * 60 * 1_000))
    .toISOString();
}

export type CommittedRoomPushEvent = {
  eventType: "game_started" | "game_finished";
  sourceEventID: string;
  matchID: string;
};

export function committedRoomPushEvents(
  room: Entity,
): CommittedRoomPushEvent[] {
  const status = clean(room?.status).toLowerCase();
  const matchID = clean(room?.match_id);
  if (!matchID) return [];
  if (status === "playing" && clean(room?.game_started_event_id)) {
    return [{
      eventType: "game_started",
      sourceEventID: clean(room.game_started_event_id),
      matchID,
    }];
  }
  if (status === "finished" && clean(room?.game_finished_event_id)) {
    return [{
      eventType: "game_finished",
      sourceEventID: clean(room.game_finished_event_id),
      matchID,
    }];
  }
  return [];
}

export async function repairCommittedRoomPushEvents(input: {
  eventStore: any;
  room: Entity;
  persist: <T>(writer: () => Promise<T>) => Promise<T>;
  now?: Date;
  randomUUID?: () => string;
}): Promise<number> {
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  let created = 0;
  for (const event of committedRoomPushEvents(input.room)) {
    const expiresAt = event.eventType === "game_finished"
      ? new Date(now.getTime() + 60 * 60 * 1_000).toISOString()
      : startExpiry(input.room, now);
    if (
      event.eventType === "game_started" &&
      Date.parse(expiresAt) <= now.getTime()
    ) continue;
    if (event.eventType === "game_finished") {
      const finishedAt = Date.parse(clean(
        input.room?.terminal_intent?.decided_at || input.room?.updated_date ||
          input.room?.created_date,
      ));
      if (
        Number.isFinite(finishedAt) &&
        now.getTime() - finishedAt >= 60 * 60 * 1_000
      ) continue;
    }
    for (const recipientUserID of stableParticipantUserIDs(input.room)) {
      const dedupeKey = [event.eventType, event.sourceEventID, recipientUserID]
        .join(":");
      const existing = await input.eventStore.filter({
        dedupe_key: dedupeKey,
      }) || [];
      if (existing.length) continue;
      await input.persist(() =>
        input.eventStore.create({
          dedupe_key: dedupeKey,
          source_event_id: event.sourceEventID,
          event_type: event.eventType,
          source_type: "game_room",
          recipient_user_id: recipientUserID,
          actor_user_id: "",
          room_id: clean(input.room.id),
          match_id: event.matchID,
          state: "pending",
          attempt_count: 0,
          delivered_count: 0,
          failed_count: 0,
          delivered_token_hashes: [],
          lease_token: "",
          lease_until: now.toISOString(),
          revision: randomUUID(),
          expires_at: expiresAt,
          created_at: now.toISOString(),
          updated_at: now.toISOString(),
        })
      );
      created += 1;
    }
  }
  return created;
}
