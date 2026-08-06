export type RoomWriteStore = {
  updateMany(
    filter: Record<string, unknown>,
    update: Record<string, unknown>,
  ): Promise<{ updated?: number }>;
};

type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

export function roomWriteRevision(
  room: Entity | null | undefined,
): number | null {
  const candidate = Number(room?.room_revision);
  return Number.isSafeInteger(candidate) && candidate >= 0 ? candidate : null;
}

export function isRoomWriteCASConflict(error: unknown): boolean {
  return clean((error as { code?: unknown })?.code) === "cas_contention";
}

function casConflict(): Error {
  return Object.assign(
    new Error("Room changed concurrently; retry the action."),
    { status: 409, code: "cas_contention", retryable: true },
  );
}

function ambiguousWrite(): Error {
  return Object.assign(
    new Error("Room write result could not be reconciled."),
    { status: 503, code: "room_write_ambiguous", retryable: true },
  );
}

export async function writeRoomWithCAS(input: {
  store: RoomWriteStore;
  room: Entity;
  patch: Entity;
  read?: (roomID: string) => Promise<Entity | null>;
  randomUUID?: () => string;
}): Promise<Entity> {
  const roomID = clean(input.room?.id);
  const expectedRevision = roomWriteRevision(input.room);
  if (!roomID || expectedRevision === null) {
    throw Object.assign(
      new Error("Room write revision is missing."),
      { status: 503, code: "room_revision_missing" },
    );
  }
  if (expectedRevision >= Number.MAX_SAFE_INTEGER) {
    throw Object.assign(
      new Error("Room write revision is exhausted."),
      { status: 503, code: "room_revision_exhausted" },
    );
  }

  const writeToken = (input.randomUUID ?? (() => crypto.randomUUID()))();
  const nextRevision = expectedRevision + 1;
  const patch = {
    ...input.patch,
    room_revision: nextRevision,
    room_last_write_token: writeToken,
  };

  let result: { updated?: number };
  try {
    result = await input.store.updateMany(
      { id: roomID, room_revision: expectedRevision },
      { $set: patch },
    );
  } catch {
    if (!input.read) throw ambiguousWrite();
    try {
      const persisted = await input.read(roomID);
      if (clean(persisted?.room_last_write_token) === writeToken) {
        return persisted as Entity;
      }
    } catch {
      // The caller must retry a response-lost write only after reconciliation.
    }
    throw ambiguousWrite();
  }

  if (Number(result?.updated) !== 1) throw casConflict();
  return { ...input.room, ...patch };
}
