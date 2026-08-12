type Entity = Record<string, any>;
type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function safeActorName(value: unknown): string {
  return clean(value)
    .replace(/[\u0000-\u001F\u007F]/g, "")
    .slice(0, 48) || "An operative";
}

function inboxProjection(
  eventType: "friend_request" | "room_invite",
  actorName: unknown,
  now: Date,
) {
  const actor = safeActorName(actorName);
  const enActor = actor === "An operative" ? "An operative" : actor;
  const ruActor = actor === "An operative" ? "Оперативник" : actor;
  const esActor = actor === "An operative" ? "Un agente" : actor;
  const ukActor = actor === "An operative" ? "Оперативник" : actor;
  const copy = eventType === "friend_request"
    ? {
      en: { title: "New friend request", body: `${enActor} wants to connect.` },
      ru: {
        title: "Новый запрос в друзья",
        body: `${ruActor} хочет добавить вас в друзья.`,
      },
      es: {
        title: "Nueva solicitud de amistad",
        body: `${esActor} quiere conectar contigo.`,
      },
      uk: {
        title: "Новий запит у друзі",
        body: `${ukActor} хоче додати вас у друзі.`,
      },
    }
    : {
      en: {
        title: "Game invitation",
        body: `${enActor} invited you to a SpyClash room.`,
      },
      ru: {
        title: "Приглашение в игру",
        body: `${ruActor} приглашает вас в комнату SpyClash.`,
      },
      es: {
        title: "Invitación al juego",
        body: `${esActor} te invitó a una sala de SpyClash.`,
      },
      uk: {
        title: "Запрошення до гри",
        body: `${ukActor} запрошує вас до кімнати SpyClash.`,
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
    inbox_action_deep_link: eventType === "friend_request"
      ? "spyclash://community/requests"
      : "spyclash://community/invites",
    inbox_published_at: now.toISOString(),
    inbox_projection_version: 1,
  };
}

export function reusablePendingInviteEventID(
  invite: Entity | null | undefined,
): string {
  return clean(invite?.status) === "pending"
    ? clean(invite?.notification_event_id)
    : "";
}

export async function enqueueCommunityPushEvent(input: {
  store: any;
  persist: Persist;
  eventType: "friend_request" | "room_invite";
  sourceEventID: string;
  actorUserID: string;
  actorDisplayName?: string;
  recipientUserID: string;
  roomID?: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<Entity> {
  const dedupeKey = [
    input.eventType,
    clean(input.sourceEventID),
    clean(input.recipientUserID),
  ].join(":");
  const existing = await input.store.filter({ dedupe_key: dedupeKey }) || [];
  if (existing.length) return existing[0];
  const now = input.now || new Date();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  return await input.persist(() =>
    input.store.create({
      dedupe_key: dedupeKey,
      source_event_id: clean(input.sourceEventID),
      event_type: input.eventType,
      source_type: input.eventType === "friend_request"
        ? "friendship"
        : "room_invite",
      recipient_user_id: clean(input.recipientUserID),
      actor_user_id: clean(input.actorUserID),
      room_id: clean(input.roomID),
      match_id: "",
      ...inboxProjection(input.eventType, input.actorDisplayName, now),
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
      expires_at: new Date(
        now.getTime() +
          (input.eventType === "room_invite" ? 24 : 7 * 24) * 60 * 60 * 1_000,
      ).toISOString(),
      created_at: now.toISOString(),
      updated_at: now.toISOString(),
    })
  );
}

export async function commitCommunityPushEvent(input: {
  store: any;
  persist: Persist;
  eventType: "friend_request" | "room_invite";
  sourceEventID: string;
  actorDisplayName?: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<boolean> {
  const events = await input.store.filter(
    {
      source_event_id: clean(input.sourceEventID),
      event_type: input.eventType,
    },
    "created_date",
    2,
    0,
  ) || [];
  if (events.length !== 1) return false;
  const event = events[0];
  if (event.inbox_visible === true && clean(event.inbox_committed_at)) {
    return true;
  }
  if (clean(event.state) === "cancelled") return false;
  const now = (input.now || new Date()).toISOString();
  const revision = (input.randomUUID || (() => crypto.randomUUID()))();
  const result: Entity = await input.persist(() =>
    input.store.updateMany({
      id: event.id,
      state: event.state,
      lease_token: event.lease_token,
      revision: event.revision,
    }, {
      $set: {
        ...inboxProjection(
          input.eventType,
          input.actorDisplayName,
          new Date(now),
        ),
        inbox_visible: true,
        inbox_committed_at: now,
        revision,
        updated_at: now,
      },
    })
  );
  if (Number(result?.updated) === 1) return true;
  const reconciled = await input.store.filter(
    {
      id: event.id,
      inbox_visible: true,
    },
    "created_date",
    2,
    0,
  ) || [];
  return reconciled.length === 1 &&
    Boolean(clean(reconciled[0].inbox_committed_at));
}

export async function cancelCommunityPushEvent(input: {
  store: any;
  persist: Persist;
  eventType: "friend_request" | "room_invite";
  sourceEventID: string;
  reason: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<number> {
  const events = await input.store.filter({
    source_event_id: clean(input.sourceEventID),
    event_type: input.eventType,
  }) || [];
  const now = (input.now || new Date()).toISOString();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  let cancelled = 0;
  for (const event of events) {
    if (!clean(event.id) || clean(event.state) === "cancelled") continue;
    const result: Entity = await input.persist(() =>
      input.store.updateMany({
        id: event.id,
        state: event.state,
        lease_token: event.lease_token,
        revision: event.revision,
      }, {
        $set: {
          state: "cancelled",
          inbox_visible: false,
          lease_token: "",
          lease_until: now,
          revision: randomUUID(),
          next_attempt_at: null,
          last_error_code: clean(input.reason).slice(0, 80),
          updated_at: now,
        },
      })
    );
    cancelled += Number(result?.updated) === 1 ? 1 : 0;
  }
  return cancelled;
}
