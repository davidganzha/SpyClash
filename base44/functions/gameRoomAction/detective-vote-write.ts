type Entity = Record<string, unknown>;

type VoteWriteDelay = (milliseconds: number) => Promise<void>;

const DEFAULT_BACKOFF_MILLISECONDS = [20, 55, 90, 125, 160];

async function defaultDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Commits one vote transition against the latest room revision. A room that
 * became settled after this request lost a CAS race is returned as success;
 * the same settled room supplied as the request's initial snapshot still goes
 * through buildPatch and is rejected as a genuinely stale later request.
 */
export async function commitDetectiveVoteCastWithRetry<T extends Entity>(
  input: {
    initialRoom: T;
    buildPatch: (latest: T) => Entity;
    write: (latest: T, patch: Entity) => Promise<T>;
    read: (roomID: string) => Promise<T | null | undefined>;
    isConflict: (error: unknown) => boolean;
    isSettledAfterConflict: (latest: T) => boolean;
    delay?: VoteWriteDelay;
    attempts?: number;
  },
): Promise<T> {
  const roomID = String(input.initialRoom?.id ?? "").trim();
  if (!roomID) {
    throw Object.assign(new Error("Room not found"), { status: 404 });
  }
  const attempts = Number.isSafeInteger(input.attempts) &&
      Number(input.attempts) > 0
    ? Math.min(8, Number(input.attempts))
    : 6;
  const delay = input.delay ?? defaultDelay;
  let latest = input.initialRoom;
  let lostCAS = false;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (lostCAS) {
      const refreshed = await input.read(roomID);
      if (!refreshed) {
        throw Object.assign(new Error("Room not found"), { status: 404 });
      }
      latest = refreshed;
      if (input.isSettledAfterConflict(latest)) return latest;
    }

    const patch = input.buildPatch(latest) ?? {};
    if (!Object.keys(patch).length) return latest;

    try {
      return await input.write(latest, patch);
    } catch (error) {
      if (!input.isConflict(error) || attempt === attempts - 1) throw error;
      lostCAS = true;
      await delay(DEFAULT_BACKOFF_MILLISECONDS[attempt] ?? 200);
    }
  }

  throw Object.assign(
    new Error("The detective vote could not be committed; retry the action."),
    { status: 409, code: "detective_vote_write_unverified" },
  );
}
