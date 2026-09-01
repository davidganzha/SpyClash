import { incomingRoomInviteHasAcceptedFriendship } from "./community.ts";

export const ROOM_INVITE_PAGE_SIZE = 100;
export const ROOM_INVITE_MAX_PAGES = 100;
export const ROOM_INVITE_RESULT_LIMIT = 100;

export type RoomInviteEntity = Record<string, unknown>;

type RoomInviteStore = {
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

function roomInviteSignature(invite: RoomInviteEntity): string {
  return [
    clean(invite.sender_user_id),
    clean(invite.recipient_user_id),
    clean(invite.status).toLowerCase(),
    clean(invite.room_id),
    clean(invite.room_code),
    clean(invite.created_at || invite.created_date),
  ].join("\u0000");
}

function stableByID(
  invitations: Iterable<RoomInviteEntity>,
): RoomInviteEntity[] {
  return [...invitations].sort((left, right) => {
    const leftID = clean(left.id);
    const rightID = clean(right.id);
    return leftID < rightID ? -1 : leftID > rightID ? 1 : 0;
  });
}

function newestFirst(invitations: Iterable<RoomInviteEntity>) {
  return [...invitations].sort((first, second) =>
    Date.parse(clean(second.created_at || second.created_date)) -
    Date.parse(clean(first.created_at || first.created_date))
  );
}

export async function filterAllRoomInvites(
  store: RoomInviteStore,
  query: Record<string, unknown>,
): Promise<RoomInviteEntity[]> {
  const byID = new Map<string, RoomInviteEntity>();
  const fullPageFingerprints = new Set<string>();

  for (
    let pageIndex = 0;
    pageIndex < ROOM_INVITE_MAX_PAGES;
    pageIndex += 1
  ) {
    const page = await store.filter(
      query,
      "id",
      ROOM_INVITE_PAGE_SIZE,
      pageIndex * ROOM_INVITE_PAGE_SIZE,
    );
    if (!Array.isArray(page) || page.length > ROOM_INVITE_PAGE_SIZE) {
      throw unavailable("RoomInvite returned an invalid pagination page.");
    }

    const pageIDs: string[] = [];
    for (const candidate of page) {
      if (
        !candidate || typeof candidate !== "object" ||
        Array.isArray(candidate)
      ) {
        throw unavailable("RoomInvite pagination returned an invalid record.");
      }
      const invite = candidate as RoomInviteEntity;
      const id = clean(invite.id);
      if (!id) {
        throw unavailable(
          "RoomInvite pagination returned a record without an id.",
        );
      }
      pageIDs.push(id);

      const existing = byID.get(id);
      if (
        existing &&
        roomInviteSignature(existing) !== roomInviteSignature(invite)
      ) {
        throw unavailable(
          `RoomInvite pagination returned conflicting record id ${id}.`,
        );
      }
      if (!existing) byID.set(id, invite);
    }

    if (page.length === ROOM_INVITE_PAGE_SIZE) {
      const fingerprint = pageIDs.join("\u0001");
      if (fullPageFingerprints.has(fingerprint)) {
        throw unavailable("RoomInvite pagination repeated a full page.");
      }
      fullPageFingerprints.add(fingerprint);
    }
    if (page.length < ROOM_INVITE_PAGE_SIZE) {
      return stableByID(byID.values());
    }
  }

  throw unavailable(
    `RoomInvite pagination exceeded the ${ROOM_INVITE_MAX_PAGES}-page safety ceiling.`,
  );
}

export async function loadIncomingRoomInvites(
  store: RoomInviteStore,
  currentUserID: string,
  relationships: RoomInviteEntity[] | Promise<RoomInviteEntity[]>,
): Promise<RoomInviteEntity[]> {
  const [invitations, resolvedRelationships] = await Promise.all([
    filterAllRoomInvites(store, {
      recipient_user_id: currentUserID,
      status: ["pending", "accepted"],
    }),
    relationships,
  ]);
  return newestFirst(invitations).filter((invite) =>
    incomingRoomInviteHasAcceptedFriendship(
      invite,
      resolvedRelationships,
      currentUserID,
    )
  ).slice(0, ROOM_INVITE_RESULT_LIMIT);
}
