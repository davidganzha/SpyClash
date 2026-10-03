type Entity = Record<string, any>;

const LOOKUP_BATCH_SIZE = 50;
export const ROOM_INVITE_LIFETIME_MS = 24 * 60 * 60 * 1_000;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

/** Invite attention ends on joining by any route, not only the invite button. */
export function roomInviteIsActionable(
  invite: Entity,
  room: Entity | null | undefined,
  userID: string,
  now = new Date(),
  userEmail = "",
): boolean {
  if (!room || clean(room.id) !== clean(invite.room_id) || room.close_intent) {
    return false;
  }
  if (
    clean(invite.recipient_user_id) !== userID ||
    !["pending", "accepted"].includes(clean(invite.status).toLowerCase()) ||
    clean(room.status).toLowerCase() !== "waiting"
  ) return false;
  const createdAt = Date.parse(clean(invite.created_at || invite.created_date));
  if (
    Number.isFinite(createdAt) &&
    createdAt + ROOM_INVITE_LIFETIME_MS <= now.getTime()
  ) return false;
  const email = clean(userEmail).toLowerCase();
  const joined = (Array.isArray(room.players) ? room.players : []).some((
    player: Entity,
  ) =>
    clean(player.user_id) === userID ||
    (email && clean(player.email).toLowerCase() === email)
  );
  return !joined;
}

/** Bounded batch lookups avoid one GameRoom request for every invitation. */
export async function actionableRoomInvites(input: {
  invitations: Entity[];
  roomStore: any;
  userID: string;
  userEmail?: string;
  now?: Date;
}): Promise<Entity[]> {
  const roomIDs = [
    ...new Set(
      input.invitations.map((invite) => clean(invite.room_id)).filter(Boolean),
    ),
  ];
  const rooms = new Map<string, Entity>();
  for (let offset = 0; offset < roomIDs.length; offset += LOOKUP_BATCH_SIZE) {
    const batch = roomIDs.slice(offset, offset + LOOKUP_BATCH_SIZE);
    const rows: Entity[] = await input.roomStore.filter(
      { id: { $in: batch } },
      "id",
      batch.length,
      0,
    ) || [];
    for (const room of rows) rooms.set(clean(room.id), room);
  }
  return input.invitations.filter((invite) =>
    roomInviteIsActionable(
      invite,
      rooms.get(clean(invite.room_id)),
      input.userID,
      input.now,
      input.userEmail,
    )
  );
}
