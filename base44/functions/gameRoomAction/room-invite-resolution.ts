type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

/** One scoped write resolves every invitation after any successful join route. */
export async function resolveRoomInvitesAfterJoin(input: {
  store: any;
  room: Entity;
  userID: string;
  userEmail: string;
  assertActorLease: () => Promise<void>;
  now?: Date;
}): Promise<void> {
  const userID = clean(input.userID);
  const roomID = clean(input.room.id);
  const email = clean(input.userEmail).toLowerCase();
  const isMember = (Array.isArray(input.room.players) ? input.room.players : [])
    .some((player: Entity) =>
      clean(player.user_id) === userID ||
      (email && clean(player.email).toLowerCase() === email)
    );
  if (!userID || !roomID || !isMember) {
    throw Object.assign(
      new Error("Room invite resolution requires confirmed membership"),
      { status: 503 },
    );
  }
  const query = {
    recipient_user_id: userID,
    room_id: roomID,
    status: { $in: ["pending", "accepted"] },
  };
  await input.assertActorLease();
  try {
    // Expired is already a supported terminal state. Keeping the source row
    // avoids losing event identity before the recipient's cleanup can cancel
    // its outbox, and permits safely replaying a lost join response.
    const result = await input.store.updateMany(query, {
      $set: {
        status: "expired",
        updated_at: (input.now || new Date()).toISOString(),
      },
    });
    if (!Number.isFinite(result?.updated)) {
      throw new Error("Room invite resolution was not acknowledged");
    }
  } catch (error) {
    const pending = await input.store.filter(query, "id", 1, 0);
    if (!Array.isArray(pending) || pending.length) throw error;
    // The write committed but its response was lost; no live invite remains.
  }
}
