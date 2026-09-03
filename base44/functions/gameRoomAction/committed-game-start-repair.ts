type MaybePromise<T> = T | Promise<T>;

export type CommittedGameStartIdentity = {
  matchID: string;
  startedEventID: string;
};

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function reconciliationChanged(): Error {
  return Object.assign(
    new Error("The committed game start changed during reconciliation."),
    { status: 409, code: "game_start_reconciliation_changed" },
  );
}

function roomUnavailable(): Error {
  return Object.assign(new Error("Room not found"), { status: 404 });
}

export function committedGameStartIdentity(
  room: Record<string, unknown> | null | undefined,
): CommittedGameStartIdentity | null {
  const matchID = clean(room?.match_id);
  const startedEventID = clean(room?.game_started_event_id);
  return clean(room?.status).toLowerCase() === "playing" && matchID &&
      startedEventID
    ? { matchID, startedEventID }
    : null;
}

function assertExactCommittedGameStart(
  room: Record<string, unknown>,
  expected: CommittedGameStartIdentity,
): void {
  const current = committedGameStartIdentity(room);
  if (
    !current || current.matchID !== expected.matchID ||
    current.startedEventID !== expected.startedEventID
  ) {
    throw reconciliationChanged();
  }
}

/**
 * Repairs only the exact already-committed start observed by the read-only
 * reconciliation pass. Identity-bearing outbox repair remains inside a newly
 * acquired, exact current-participant lifecycle lease set. Realtime fanout is
 * deliberately deferred until that lease set is released; callers must make
 * that fanout update-only so account cleanup cannot be undone.
 */
export async function repairCommittedGameStartWithFreshLeases<
  Room extends Record<string, unknown>,
  LeaseContext,
>(input: {
  expected: CommittedGameStartIdentity;
  refetch: () => Promise<Room | null | undefined>;
  assertParticipant: (room: Room) => MaybePromise<void>;
  lifecycleUserIDs: (room: Room) => Promise<readonly unknown[]>;
  withFreshLeases: <T>(
    userIDs: readonly unknown[],
    action: (context: LeaseContext) => Promise<T>,
  ) => Promise<T>;
  currentUserIDs: (room: Room) => Promise<readonly unknown[]>;
  assertExactLeaseCoverage: (
    context: LeaseContext,
    userIDs: readonly unknown[],
  ) => MaybePromise<void>;
  assertLeasesActive: (context: LeaseContext) => Promise<void>;
  migrate: (room: Room, userIDs: readonly unknown[]) => Promise<Room>;
  reconcile: (room: Room) => Promise<Room>;
  fanout: (room: Room) => Promise<void>;
}): Promise<Room> {
  const acquisitionRoom = await input.refetch();
  if (!acquisitionRoom) throw roomUnavailable();
  await input.assertParticipant(acquisitionRoom);
  assertExactCommittedGameStart(acquisitionRoom, input.expected);
  const acquisitionUserIDs = await input.lifecycleUserIDs(acquisitionRoom);

  const finalRoom = await input.withFreshLeases(
    acquisitionUserIDs,
    async (context) => {
      const latestRoom = await input.refetch();
      if (!latestRoom) throw roomUnavailable();
      await input.assertParticipant(latestRoom);
      assertExactCommittedGameStart(latestRoom, input.expected);

      const currentUserIDs = await input.currentUserIDs(latestRoom);
      await input.assertExactLeaseCoverage(context, currentUserIDs);
      const migratedRoom = await input.migrate(latestRoom, currentUserIDs);
      await input.assertParticipant(migratedRoom);
      assertExactCommittedGameStart(migratedRoom, input.expected);

      const reconciledRoom = await input.reconcile(migratedRoom);
      assertExactCommittedGameStart(reconciledRoom, input.expected);

      // Safe acknowledgement and other non-membership fast paths can run
      // independently of the room lease. Refetch once more so the signal never
      // republishes a stale revision after the idempotent outbox repair.
      const finalRoom = await input.refetch();
      if (!finalRoom) throw roomUnavailable();
      await input.assertParticipant(finalRoom);
      assertExactCommittedGameStart(finalRoom, input.expected);
      const finalUserIDs = await input.currentUserIDs(finalRoom);
      await input.assertExactLeaseCoverage(context, finalUserIDs);
      await input.assertLeasesActive(context);
      return finalRoom;
    },
  );
  await input.fanout(finalRoom);
  return finalRoom;
}
