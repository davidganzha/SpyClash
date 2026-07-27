const ENTITY_PAGE_SIZE = 100;

type Entity = Record<string, unknown>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

async function allMatching(store: any, filter: Entity): Promise<Entity[]> {
  const records: Entity[] = [];
  for (let skip = 0;; skip += ENTITY_PAGE_SIZE) {
    const page: Entity[] = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
  }
}

async function deleteUnique(
  store: any,
  records: Entity[],
  persist: <T>(writer: () => Promise<T>) => Promise<T>,
): Promise<number> {
  const ids = [
    ...new Set(records.map((record) => clean(record.id)).filter(Boolean)),
  ];
  for (const id of ids) {
    await persist(() => store.delete(id));
  }
  return ids.length;
}

async function cancelPairPushEvents(input: {
  store: any;
  firstUserID: string;
  secondUserID: string;
  persist: <T>(writer: () => Promise<T>) => Promise<T>;
}): Promise<number> {
  if (!input.store) return 0;
  const groups = await Promise.all(
    [
      [input.firstUserID, input.secondUserID],
      [input.secondUserID, input.firstUserID],
    ].flatMap(([actor, recipient]) =>
      ["friend_request", "room_invite"].map((eventType) =>
        allMatching(input.store, {
          actor_user_id: actor,
          recipient_user_id: recipient,
          event_type: eventType,
        })
      )
    ),
  );
  const events = groups.flat().filter((event, index, all) =>
    all.findIndex((candidate) => clean(candidate.id) === clean(event.id)) ===
      index
  );
  let cancelled = 0;
  const now = new Date().toISOString();
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
          revision: crypto.randomUUID(),
          next_attempt_at: null,
          last_error_code: "relationship_blocked",
          updated_at: now,
        },
      })
    );
    cancelled += Number(result?.updated) === 1 ? 1 : 0;
  }
  return cancelled;
}

export async function deleteBlockedPairContent(input: {
  profileCommentStore: any;
  roomInviteStore: any;
  pushEventStore?: any;
  firstUserID: string;
  secondUserID: string;
  persist?: <T>(writer: () => Promise<T>) => Promise<T>;
}): Promise<
  { profileComments: number; roomInvites: number; pushEvents: number }
> {
  const firstUserID = clean(input.firstUserID);
  const secondUserID = clean(input.secondUserID);
  if (!firstUserID || !secondUserID || firstUserID === secondUserID) {
    throw new Error("Two distinct users are required for block cleanup.");
  }

  const [commentsForward, commentsReverse, invitesForward, invitesReverse] =
    await Promise.all([
      allMatching(input.profileCommentStore, {
        author_user_id: firstUserID,
        target_user_id: secondUserID,
      }),
      allMatching(input.profileCommentStore, {
        author_user_id: secondUserID,
        target_user_id: firstUserID,
      }),
      allMatching(input.roomInviteStore, {
        sender_user_id: firstUserID,
        recipient_user_id: secondUserID,
      }),
      allMatching(input.roomInviteStore, {
        sender_user_id: secondUserID,
        recipient_user_id: firstUserID,
      }),
    ]);

  const persist = input.persist || (async (writer) => await writer());
  const profileComments = await deleteUnique(input.profileCommentStore, [
    ...commentsForward,
    ...commentsReverse,
  ], persist);
  const roomInvites = await deleteUnique(
    input.roomInviteStore,
    [...invitesForward, ...invitesReverse],
    persist,
  );
  const pushEvents = await cancelPairPushEvents({
    store: input.pushEventStore,
    firstUserID,
    secondUserID,
    persist,
  });
  return { profileComments, roomInvites, pushEvents };
}

export function blockedCounterpartIDs(
  relationships: Entity[],
  userID: unknown,
): Set<string> {
  const normalizedUserID = clean(userID);
  const blocked = new Set<string>();
  for (const relationship of relationships) {
    if (clean(relationship.status) !== "blocked") continue;
    const requesterID = clean(relationship.requester_id);
    const addresseeID = clean(relationship.addressee_id);
    if (requesterID === normalizedUserID && addresseeID) {
      blocked.add(addresseeID);
    }
    if (addresseeID === normalizedUserID && requesterID) {
      blocked.add(requesterID);
    }
  }
  return blocked;
}
