type Entity = Record<string, any>;

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function isExplicitFinalizer(action: unknown): boolean {
  return ["finalize_expired_room", "finish_room"].includes(clean(action));
}

function isRetryableLeaseConflict(error: any): boolean {
  return error?.retryable === true &&
    ["active_lease", "cas_contention"].includes(clean(error?.code));
}

/**
 * A competing finalizer can own the participant lease before its terminal
 * intent is visible. Observe that winner for a short bounded window instead
 * of multiplying lease acquisition retries across every connected client.
 */
export async function reconcileTerminalFinalizationAfterLeaseConflict(input: {
  action: unknown;
  error: unknown;
  refetch: () => Promise<Entity | null>;
  validate: (room: Entity) => void;
  delay: (milliseconds: number) => Promise<void>;
  retryDelays?: readonly number[];
}): Promise<Entity> {
  if (
    !isExplicitFinalizer(input.action) || !isRetryableLeaseConflict(input.error)
  ) {
    throw input.error;
  }

  for (const milliseconds of input.retryDelays || [80, 200, 420, 800]) {
    await input.delay(milliseconds);
    const room = await input.refetch();
    if (!room) {
      throw Object.assign(new Error("Room not found"), { status: 404 });
    }
    input.validate(room);
    if (clean(room.status).toLowerCase() === "finished") return room;
  }
  throw input.error;
}
