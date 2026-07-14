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

export async function deleteBlockedPairContent(input: {
  profileCommentStore: any;
  roomInviteStore: any;
  firstUserID: string;
  secondUserID: string;
  persist?: <T>(writer: () => Promise<T>) => Promise<T>;
}): Promise<{ profileComments: number; roomInvites: number }> {
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
  return { profileComments, roomInvites };
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
