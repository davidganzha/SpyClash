import { boundedText, clean } from "./contracts.ts";

export type PushEvent = Record<string, any>;
export type SourceContext = {
  valid: boolean;
  retryable?: boolean;
  actorName?: string;
  winner?: string;
  reason?: string;
};

const PROCESSING_LEASE_MS = 90_000;
const TERMINAL_STATES = new Set([
  "delivered",
  "partial",
  "no_devices",
  "cancelled",
  "failed",
]);

async function one(store: any, filter: Record<string, unknown>) {
  const rows = await store.filter(filter, "created_date", 2, 0) || [];
  return rows[0] || null;
}

function actorDisplayName(user: PushEvent | null): string {
  return boundedText(
    user?.display_name || user?.full_name || "An operative",
    48,
  ) ||
    "An operative";
}

function recentlyQueued(event: PushEvent, now = new Date()): boolean {
  const created = Date.parse(clean(event.created_at || event.created_date));
  return Number.isFinite(created) && now.getTime() - created < 2 * 60 * 1_000;
}

export function pushEventLifecycleUserIDs(event: PushEvent): string[] {
  const userIDs = [clean(event.recipient_user_id)];
  if (["friend_request", "room_invite"].includes(clean(event.event_type))) {
    userIDs.push(clean(event.actor_user_id));
  }
  return [...new Set(userIDs.filter(Boolean))].sort();
}

export function alertCollapseID(event: PushEvent): string {
  const gameEvent = ["game_started", "game_finished"].includes(
    clean(event.event_type),
  );
  const matchID = clean(event.match_id);
  if (gameEvent && matchID) return `game:${matchID}`.slice(0, 64);
  return `event:${clean(event.source_event_id)}`.slice(0, 64);
}

export async function validatePushSource(
  base44: any,
  event: PushEvent,
): Promise<SourceContext> {
  const sourceEventID = clean(event.source_event_id);
  const recipientID = clean(event.recipient_user_id);
  const actorID = clean(event.actor_user_id);
  if (!sourceEventID || !recipientID) {
    return { valid: false, reason: "invalid_event" };
  }

  if (event.event_type === "friend_request") {
    const friendship = await one(
      base44.asServiceRole.entities.Friendship,
      { request_event_id: sourceEventID },
    );
    if (!friendship) {
      return {
        valid: false,
        retryable: recentlyQueued(event),
        reason: "friend_request_source_pending",
      };
    }
    if (
      clean(friendship.status) !== "pending" ||
      clean(friendship.requester_id) !== actorID ||
      clean(friendship.addressee_id) !== recipientID
    ) return { valid: false, reason: "friend_request_stale" };
    const actor = await one(base44.asServiceRole.entities.User, {
      id: actorID,
    });
    return { valid: Boolean(actor), actorName: actorDisplayName(actor) };
  }

  if (event.event_type === "room_invite") {
    const invite = await one(
      base44.asServiceRole.entities.RoomInvite,
      { notification_event_id: sourceEventID },
    );
    if (!invite) {
      return {
        valid: false,
        retryable: recentlyQueued(event),
        reason: "room_invite_source_pending",
      };
    }
    if (
      clean(invite.status) !== "pending" ||
      clean(invite.sender_user_id) !== actorID ||
      clean(invite.recipient_user_id) !== recipientID ||
      clean(invite.room_id) !== clean(event.room_id)
    ) return { valid: false, reason: "room_invite_stale" };
    const room = await one(base44.asServiceRole.entities.GameRoom, {
      id: clean(event.room_id),
    });
    if (!room || clean(room.status) !== "waiting") {
      return { valid: false, reason: "room_closed" };
    }
    const actor = await one(base44.asServiceRole.entities.User, {
      id: actorID,
    });
    return { valid: Boolean(actor), actorName: actorDisplayName(actor) };
  }

  const room = await one(base44.asServiceRole.entities.GameRoom, {
    id: clean(event.room_id),
  });
  const participantIDs = Array.isArray(room?.participant_user_ids)
    ? room.participant_user_ids.map(clean)
    : [];
  const playerIDs = Array.isArray(room?.players)
    ? room.players.map((player: PushEvent) => clean(player?.user_id))
    : [];
  if (!room) {
    return {
      valid: false,
      retryable: recentlyQueued(event),
      reason: "game_source_pending",
    };
  }
  if (![...participantIDs, ...playerIDs].includes(recipientID)) {
    return { valid: false, reason: "room_membership_stale" };
  }

  if (event.event_type === "game_started") {
    if (
      clean(room.game_started_event_id) !== sourceEventID &&
      clean(room.status) === "roulette" && recentlyQueued(event)
    ) {
      return { valid: false, retryable: true, reason: "game_start_pending" };
    }
    return {
      valid: clean(room.status) === "playing" &&
        clean(event.match_id) === clean(room.match_id) &&
        clean(room.game_started_event_id) === sourceEventID,
      reason: "game_start_stale",
    };
  }
  if (event.event_type === "game_finished") {
    const terminalMatchID = clean(room.terminal_intent?.match_id);
    if (
      clean(room.status) !== "finished" &&
      terminalMatchID === clean(event.match_id)
    ) {
      return { valid: false, retryable: true, reason: "game_finish_pending" };
    }
    return {
      valid: clean(room.status) === "finished" &&
        clean(event.match_id) === clean(room.match_id) &&
        clean(room.game_finished_event_id) === sourceEventID,
      winner: clean(room.winner),
      reason: "game_finish_stale",
    };
  }
  return { valid: false, reason: "unknown_event" };
}

export function preferenceAllows(
  registration: PushEvent,
  eventType: string,
): boolean {
  if (
    registration.status !== "active" || registration.alert_authorized !== true
  ) {
    return false;
  }
  if (eventType === "friend_request") {
    return registration.friend_requests_enabled !== false;
  }
  if (eventType === "room_invite") {
    return registration.room_invites_enabled !== false;
  }
  return registration.game_updates_enabled !== false;
}

type Language = "en" | "ru" | "es";

function language(value: unknown): Language {
  const normalized = clean(value).toLowerCase().split(/[-_]/)[0];
  return normalized === "ru" || normalized === "es" ? normalized : "en";
}

export function alertPayload(
  event: PushEvent,
  source: SourceContext,
  locale: unknown,
): Record<string, unknown> {
  const lang = language(locale);
  const actor = source.actorName ||
    (lang === "ru" ? "Оперативник" : "An operative");
  const copy: Record<
    string,
    Record<Language, { title: string; body: string }>
  > = {
    friend_request: {
      en: { title: "New friend request", body: `${actor} wants to connect.` },
      ru: {
        title: "Новый запрос в друзья",
        body: `${actor} хочет добавить вас в друзья.`,
      },
      es: {
        title: "Nueva solicitud de amistad",
        body: `${actor} quiere conectar contigo.`,
      },
    },
    room_invite: {
      en: {
        title: "Game invitation",
        body: `${actor} invited you to a SpyClash room.`,
      },
      ru: {
        title: "Приглашение в игру",
        body: `${actor} приглашает вас в комнату SpyClash.`,
      },
      es: {
        title: "Invitación al juego",
        body: `${actor} te invitó a una sala de SpyClash.`,
      },
    },
    game_started: {
      en: { title: "Mission started", body: "Your SpyClash game is now live." },
      ru: {
        title: "Игра началась",
        body: "Ваша миссия SpyClash уже началась.",
      },
      es: {
        title: "La misión comenzó",
        body: "Tu partida de SpyClash ya comenzó.",
      },
    },
    game_finished: {
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
    },
  };
  const selected = copy[clean(event.event_type)]?.[lang] ||
    copy.game_started[lang];
  const category = event.event_type === "friend_request"
    ? "SPYCLASH_FRIEND_REQUEST"
    : event.event_type === "room_invite"
    ? "SPYCLASH_ROOM_INVITE"
    : "SPYCLASH_GAME_UPDATE";
  const threadID = event.room_id ? `room:${clean(event.room_id)}` : "community";
  // Role, secret word, emails, raw user ids, and room codes are intentionally
  // excluded from ordinary lock-screen notifications. ActivityKit receives
  // user-specific secret state through its separate token path.
  return {
    aps: {
      alert: selected,
      category,
      "thread-id": threadID.slice(0, 64),
      "content-available": 1,
    },
    event_type: event.event_type === "game_finished"
      ? "game_ended"
      : clean(event.event_type),
    event_id: clean(event.source_event_id),
    deep_link: event.event_type === "friend_request"
      ? "spyclash://community/requests"
      : event.event_type === "room_invite"
      ? "spyclash://community/invites"
      : `spyclash://game?room_id=${
        encodeURIComponent(boundedText(event.room_id, 200))
      }`,
    room_id: boundedText(event.room_id, 200) || undefined,
    match_id: boundedText(event.match_id, 200) || undefined,
  };
}

export async function claimPushEvent(
  store: any,
  event: PushEvent,
  now = new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<PushEvent | null> {
  const state = clean(event.state);
  if (TERMINAL_STATES.has(state)) return null;
  const nextAttempt = Date.parse(clean(event.next_attempt_at));
  if (
    state === "retry" && Number.isFinite(nextAttempt) &&
    nextAttempt > now.getTime()
  ) {
    return null;
  }
  const leaseUntil = Date.parse(clean(event.lease_until));
  if (
    state === "processing" && Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime()
  ) {
    return null;
  }
  const token = `push:${randomUUID()}`;
  const revision = randomUUID();
  const next = {
    ...event,
    state: "processing",
    lease_token: token,
    lease_until: new Date(now.getTime() + PROCESSING_LEASE_MS).toISOString(),
    revision,
    attempt_count: Number(event.attempt_count || 0) + 1,
    updated_at: now.toISOString(),
  };
  const result = await store.updateMany(
    {
      id: event.id,
      state: event.state,
      lease_token: event.lease_token,
      revision: event.revision,
    },
    {
      $set: {
        state: next.state,
        lease_token: next.lease_token,
        lease_until: next.lease_until,
        revision: next.revision,
        attempt_count: next.attempt_count,
        updated_at: next.updated_at,
      },
    },
  );
  return Number(result?.updated) === 1 ? next : null;
}

export async function completePushEvent(input: {
  store: any;
  claimed: PushEvent;
  state:
    | "retry"
    | "delivered"
    | "partial"
    | "no_devices"
    | "cancelled"
    | "failed";
  deliveredCount?: number;
  failedCount?: number;
  deliveredTokenHashes?: string[];
  errorCode?: string;
  nextAttemptAt?: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<boolean> {
  const now = input.now || new Date();
  const revision = (input.randomUUID || (() => crypto.randomUUID()))();
  const patch: PushEvent = {
    state: input.state,
    delivered_count: input.deliveredCount === undefined
      ? Number(input.claimed.delivered_count || 0)
      : Number(input.deliveredCount),
    failed_count: input.failedCount === undefined
      ? Number(input.claimed.failed_count || 0)
      : Number(input.failedCount),
    delivered_token_hashes: [
      ...new Set(
        (input.deliveredTokenHashes === undefined
          ? Array.isArray(input.claimed.delivered_token_hashes)
            ? input.claimed.delivered_token_hashes
            : []
          : input.deliveredTokenHashes).map(clean).filter(Boolean),
      ),
    ].slice(0, 8),
    last_error_code: boundedText(input.errorCode, 80),
    next_attempt_at: input.nextAttemptAt || null,
    lease_token: "",
    lease_until: now.toISOString(),
    revision,
    updated_at: now.toISOString(),
  };
  if (["delivered", "partial", "no_devices"].includes(input.state)) {
    patch.delivered_at = now.toISOString();
  }
  const result = await input.store.updateMany(
    {
      id: input.claimed.id,
      state: "processing",
      lease_token: input.claimed.lease_token,
      revision: input.claimed.revision,
    },
    { $set: patch },
  );
  return Number(result?.updated) === 1;
}

export function retryAt(attemptCount: number, now = new Date()): string {
  const seconds = Math.min(3600, 15 * 2 ** Math.max(0, attemptCount - 1));
  return new Date(now.getTime() + seconds * 1_000).toISOString();
}
