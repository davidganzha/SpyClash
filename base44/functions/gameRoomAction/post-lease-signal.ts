const LATEST_SIGNAL_REPAIR_BACKOFF_MILLISECONDS = [25, 50, 100, 200, 400];

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function retryableLatestSignalRepair(error: unknown): boolean {
  return [
    "active_lease",
    "cas_contention",
    "room_membership_changed",
    "room_signal_authoritative_read_pending",
  ].includes(clean((error as { code?: unknown })?.code));
}

async function defaultSignalRepairDelay(milliseconds: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Retries only a post-commit signal that lost lifecycle-lease contention.
 * Every repair iteration reloads the authoritative candidate before its
 * callback reacquires (and later releases) the exact identity leases. This
 * helper never bypasses or mutates lifecycle ownership itself.
 */
export async function runLatestRoomSignalAfterLeaseContention<T>(input: {
  initial: T;
  attempt: (
    candidate: T,
    context: { attempt: number; isRepair: boolean },
  ) => Promise<boolean>;
  loadLatest: (current: T) => Promise<T | null | undefined>;
  delay?: (milliseconds: number) => Promise<void>;
  attempts?: number;
}): Promise<boolean> {
  const requestedAttempts = Number.isFinite(input.attempts)
    ? Math.trunc(input.attempts as number)
    : 6;
  const attempts = Math.min(
    LATEST_SIGNAL_REPAIR_BACKOFF_MILLISECONDS.length + 1,
    Math.max(1, requestedAttempts),
  );
  const delay = input.delay ?? defaultSignalRepairDelay;
  let candidate = input.initial;
  let lastError: unknown;

  for (let index = 0; index < attempts; index += 1) {
    if (index > 0) {
      await delay(LATEST_SIGNAL_REPAIR_BACKOFF_MILLISECONDS[index - 1]);
      try {
        const latest = await input.loadLatest(candidate);
        if (!latest) continue;
        candidate = latest;
      } catch (error) {
        lastError = error;
        if (!retryableLatestSignalRepair(error)) throw error;
        continue;
      }
    }

    try {
      return await input.attempt(candidate, {
        attempt: index + 1,
        isRepair: index > 0,
      });
    } catch (error) {
      lastError = error;
      if (!retryableLatestSignalRepair(error) || index === attempts - 1) {
        throw error;
      }
    }
  }

  if (lastError) throw lastError;
  return false;
}

export type RoomSignalWorkBudget = {
  assertCanStart: () => void;
};

/**
 * The budget stops NEW work; it must never detach an acquired account lease.
 * Returning a serverless response while a write/release is still in flight
 * can terminate that work and leave every account writer blocked for its TTL.
 */
export async function runPostLeaseSignalWithinDeadline(input: {
  timeoutMS: number;
  leasedOperation: (budget: RoomSignalWorkBudget) => Promise<boolean>;
  logError?: (message: string, error: unknown) => void;
  nowEpochMS?: () => number;
}): Promise<boolean> {
  const nowEpochMS = input.nowEpochMS ?? Date.now;
  const deadline = nowEpochMS() + Math.max(1, Math.floor(input.timeoutMS));
  const budget: RoomSignalWorkBudget = {
    assertCanStart: () => {
      if (nowEpochMS() < deadline) return;
      throw Object.assign(
        new Error("Room signal fanout exceeded its deadline."),
        {
          status: 503,
          code: "room_signal_deadline",
        },
      );
    },
  };
  try {
    budget.assertCanStart();
    return await input.leasedOperation(budget);
  } catch (error) {
    input.logError?.("room signal fanout deferred", error);
    return false;
  }
}
