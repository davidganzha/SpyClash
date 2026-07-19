type Entity = Record<string, any>;
type Persist = <T>(writer: () => Promise<T>) => Promise<T>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
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
