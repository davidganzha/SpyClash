export const FRIENDSHIP_PAGE_SIZE = 100;
export const FRIENDSHIP_MAX_PAGES = 100;

export type FriendshipEntity = Record<string, unknown>;

type FriendshipStore = {
  filter: (
    query: Record<string, unknown>,
    sort: string,
    limit: number,
    skip: number,
  ) => Promise<unknown>;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function unavailable(message: string): Error & { status: number } {
  return Object.assign(new Error(message), { status: 503 });
}

function friendshipSignature(friendship: FriendshipEntity): string {
  return [
    clean(friendship.requester_id),
    clean(friendship.addressee_id),
    clean(friendship.status).toLowerCase(),
    clean(friendship.blocked_by_id),
  ].join("\u0000");
}

function stableByID(
  friendships: Iterable<FriendshipEntity>,
): FriendshipEntity[] {
  return [...friendships].sort((left, right) => {
    const leftID = clean(left.id);
    const rightID = clean(right.id);
    return leftID < rightID ? -1 : leftID > rightID ? 1 : 0;
  });
}

export async function filterAllFriendships(
  store: FriendshipStore,
  query: Record<string, unknown>,
): Promise<FriendshipEntity[]> {
  const byID = new Map<string, FriendshipEntity>();
  const fullPageFingerprints = new Set<string>();

  for (
    let pageIndex = 0;
    pageIndex < FRIENDSHIP_MAX_PAGES;
    pageIndex += 1
  ) {
    const page = await store.filter(
      query,
      "id",
      FRIENDSHIP_PAGE_SIZE,
      pageIndex * FRIENDSHIP_PAGE_SIZE,
    );
    if (!Array.isArray(page) || page.length > FRIENDSHIP_PAGE_SIZE) {
      throw unavailable("Friendship returned an invalid pagination page.");
    }

    const pageIDs: string[] = [];
    for (const candidate of page) {
      if (
        !candidate || typeof candidate !== "object" ||
        Array.isArray(candidate)
      ) {
        throw unavailable("Friendship pagination returned an invalid record.");
      }
      const friendship = candidate as FriendshipEntity;
      const id = clean(friendship.id);
      if (!id) {
        throw unavailable(
          "Friendship pagination returned a record without an id.",
        );
      }
      pageIDs.push(id);

      const existing = byID.get(id);
      if (
        existing &&
        friendshipSignature(existing) !== friendshipSignature(friendship)
      ) {
        throw unavailable(
          `Friendship pagination returned conflicting record id ${id}.`,
        );
      }
      if (!existing) byID.set(id, friendship);
    }

    if (page.length === FRIENDSHIP_PAGE_SIZE) {
      const fingerprint = pageIDs.join("\u0001");
      if (fullPageFingerprints.has(fingerprint)) {
        throw unavailable("Friendship pagination repeated a full page.");
      }
      fullPageFingerprints.add(fingerprint);
    }
    if (page.length < FRIENDSHIP_PAGE_SIZE) {
      return stableByID(byID.values());
    }
  }

  throw unavailable(
    `Friendship pagination exceeded the ${FRIENDSHIP_MAX_PAGES}-page safety ceiling.`,
  );
}
