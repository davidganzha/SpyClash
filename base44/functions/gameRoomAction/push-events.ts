import { gameTimerDeadlineMilliseconds } from "./game-timer-policy.ts";

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

export function gamePushRecipientUserIDs(room: Entity): string[] {
  return stableUserIDs(room);
}

function committedEventMatches(
  event: Entity,
  eventType: "game_started" | "game_finished",
  sourceEventID: string,
  recipientUserID: string,
): boolean {
  const committedAt = Date.parse(clean(event?.inbox_committed_at));
  return clean(event?.event_type) === eventType &&
    clean(event?.source_event_id) === sourceEventID &&
    clean(event?.recipient_user_id) === recipientUserID &&
    clean(event?.dedupe_key) ===
      [eventType, sourceEventID, recipientUserID].join(":") &&
    event?.inbox_visible !== true && Number.isFinite(committedAt);
}

export async function gamePushCommitCoversRecipients(input: {
  store: any;
  eventType: "game_started" | "game_finished";
  sourceEventID: string;
  recipientUserIDs: readonly unknown[];
}): Promise<boolean> {
  const sourceEventID = clean(input.sourceEventID);
  const recipientUserIDs = [
    ...new Set(
      input.recipientUserIDs.map(clean).filter(Boolean),
    ),
  ].sort();
  if (!sourceEventID || !recipientUserIDs.length) return false;
  const events = await input.store.filter(
    {
      source_event_id: sourceEventID,
      event_type: input.eventType,
    },
    "created_date",
    100,
    0,
  ) || [];
  return recipientUserIDs.every((recipientUserID) =>
    events.some((event: Entity) =>
      committedEventMatches(
        event,
        input.eventType,
        sourceEventID,
        recipientUserID,
      )
    )
  );
}

function inboxProjection(
  eventType: "game_started" | "game_finished",
  roomID: string,
  now: Date,
) {
  const copy = eventType === "game_started"
    ? {
      en: { title: "Mission started", body: "Your SpyClash game is now live." },
      ru: {
        title: "Игра началась",
        body: "Ваша миссия SpyClash уже началась.",
      },
      es: {
        title: "La misión comenzó",
        body: "Tu partida de SpyClash ya comenzó.",
      },
      uk: {
        title: "Гра почалася",
        body: "Ваша місія SpyClash уже почалася.",
      },
    }
    : {
      en: {
        title: "Mission complete",
        body: "Open SpyClash to see the result.",
      },
      ru: {
        title: "Игра завершена",
        body: "Откройте SpyClash, чтобы увидеть результат.",
      },
      es: {
        title: "Misión completada",
        body: "Abre SpyClash para ver el resultado.",
      },
      uk: {
        title: "Гру завершено",
        body: "Відкрийте SpyClash, щоб побачити результат.",
      },
    };
  return {
    inbox_kind: eventType,
    inbox_importance: "important",
    inbox_title_en: copy.en.title,
    inbox_body_en: copy.en.body,
    inbox_title_ru: copy.ru.title,
    inbox_body_ru: copy.ru.body,
    inbox_title_es: copy.es.title,
    inbox_body_es: copy.es.body,
    inbox_title_uk: copy.uk.title,
    inbox_body_uk: copy.uk.body,
    inbox_action_deep_link: `spyclash://game?room_id=${
      encodeURIComponent(clean(roomID).slice(0, 200))
    }`,
    inbox_published_at: now.toISOString(),
    inbox_projection_version: 1,
  };
}

export function gamePushExpiry(
  room: Entity,
  eventType: "game_started" | "game_finished",
  now = new Date(),
): string {
  if (eventType === "game_finished") {
    return new Date(now.getTime() + 60 * 60 * 1_000).toISOString();
  }
  let timerDeadline = now.getTime() + 20 * 60 * 1_000;
  try {
    timerDeadline = gameTimerDeadlineMilliseconds(
      room,
      now.getTime(),
      5 * 60,
    );
  } catch {
    // Legacy pre-timer rooms have no authoritative start yet. Keep their
    // bounded fallback rather than retaining a stale start alert indefinitely.
  }
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
  sourceCommitted?: boolean;
}): Promise<void> {
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const store = input.base44.asServiceRole.entities.PushNotificationEvent;
  const missingEvents: Entity[] = [];
  for (const recipientUserID of stableUserIDs(input.room)) {
    const dedupeKey = [input.eventType, input.sourceEventID, recipientUserID]
      .join(":");
    const existing = await store.filter({ dedupe_key: dedupeKey }) || [];
    if (existing.length) continue;
    missingEvents.push({
      dedupe_key: dedupeKey,
      source_event_id: clean(input.sourceEventID),
      event_type: input.eventType,
      source_type: "game_room",
      recipient_user_id: recipientUserID,
      actor_user_id: clean(input.actorUserID),
      room_id: clean(input.room.id),
      match_id: clean(input.matchID),
      ...inboxProjection(input.eventType, clean(input.room.id), now),
      inbox_visible: false,
      inbox_committed_at: null,
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
    });
  }
  if (missingEvents.length) {
    // The caller already holds the complete participant lease set. Reassert it
    // once for this bounded, retry-idempotent group instead of once per
    // recipient, which turns the lifecycle work from quadratic to linear.
    await input.persist(async () => {
      for (const event of missingEvents) await store.create(event);
    });
  }
  if (input.sourceCommitted) {
    const committed = await commitGamePushEvents({
      store,
      persist: input.persist,
      eventType: input.eventType,
      sourceEventID: input.sourceEventID,
      now,
      randomUUID,
    });
    if (committed < stableUserIDs(input.room).length) {
      throw new Error("game_push_commit_incomplete");
    }
  }
}

export async function commitGamePushEvents(input: {
  store: any;
  persist: <T>(writer: () => Promise<T>) => Promise<T>;
  eventType: "game_started" | "game_finished";
  sourceEventID: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<number> {
  const events = await input.store.filter(
    {
      source_event_id: clean(input.sourceEventID),
      event_type: input.eventType,
    },
    "created_date",
    100,
    0,
  ) || [];
  const now = (input.now || new Date()).toISOString();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  let committed = 0;
  const pendingCommits: Entity[] = [];
  for (const event of events) {
    if (event.inbox_visible !== true && clean(event.inbox_committed_at)) {
      committed += 1;
      continue;
    }
    if (
      clean(event.state) === "cancelled" &&
      input.eventType !== "game_finished"
    ) continue;
    pendingCommits.push(event);
  }
  if (pendingCommits.length) {
    committed += await input.persist(async () => {
      let updated = 0;
      for (const event of pendingCommits) {
        const reviveCancelled = input.eventType === "game_finished" &&
          clean(event.state) === "cancelled";
        const result: Entity = await input.store.updateMany({
          id: event.id,
          state: event.state,
          lease_token: event.lease_token,
          revision: event.revision,
        }, {
          $set: {
            ...inboxProjection(
              input.eventType,
              clean(event.room_id),
              new Date(now),
            ),
            inbox_visible: false,
            inbox_committed_at: now,
            ...(reviveCancelled
              ? {
                state: "retry",
                lease_token: "",
                lease_until: now,
                next_attempt_at: now,
                attempt_count: 0,
                last_error_code: "committed_finish_recovered",
              }
              : {}),
            revision: randomUUID(),
            updated_at: now,
          },
        });
        updated += Number(result?.updated) === 1 ? 1 : 0;
      }
      return updated;
    });
  }
  return committed;
}
