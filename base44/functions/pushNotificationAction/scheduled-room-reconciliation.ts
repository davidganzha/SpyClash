import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

export type ReconciledRoomStatus = "finished" | "playing";
export type RoomReconciliationCheckpoint = {
  record: Entity;
  cursor: string;
};
export type RoomReconciliationPage = {
  rooms: Entity[];
  wrapped: boolean;
};
export type ScheduledRoomReconciliationCandidate = {
  room: Entity;
  status: ReconciledRoomStatus;
  source: "cursor" | "newest";
};

const CHECKPOINT_PREFIX = "internal:room-outbox-reconciliation:v1";

function checkpointKey(status: ReconciledRoomStatus): string {
  return `${CHECKPOINT_PREFIX}:${status}`;
}

function canonicalCheckpoint(rows: Entity[]): Entity | null {
  return [...rows].sort((left, right) =>
    clean(left.created_at || left.created_date).localeCompare(
      clean(right.created_at || right.created_date),
    ) || clean(left.id).localeCompare(clean(right.id))
  )[0] || null;
}

async function checkpointRows(
  store: any,
  status: ReconciledRoomStatus,
): Promise<Entity[]> {
  return await store.filter(
    { dedupe_key: checkpointKey(status), status: "withdrawn" },
    "created_date",
    100,
    0,
  ) || [];
}

/**
 * NotificationAnnouncement already provides a private, server-owned cursor
 * row with exact-CAS revision fields. A withdrawn system row cannot enter the
 * published inbox or announcement fanout, so no new client-visible schema is
 * needed solely for this maintenance checkpoint.
 */
export async function ensureRoomReconciliationCheckpoint(input: {
  store: any;
  status: ReconciledRoomStatus;
  now?: Date;
  randomUUID?: () => string;
}): Promise<RoomReconciliationCheckpoint> {
  const existing = canonicalCheckpoint(
    await checkpointRows(input.store, input.status),
  );
  if (existing) {
    return {
      record: existing,
      cursor: clean(existing.fanout_cursor_registration_id),
    };
  }

  const now = input.now || new Date();
  const nowISO = now.toISOString();
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const created = await input.store.create({
    dedupe_key: checkpointKey(input.status),
    topic: "service",
    status: "withdrawn",
    importance: "quiet",
    title_en: "Internal room reconciliation checkpoint",
    body_en: "Server-owned maintenance state; never publish.",
    expires_at: nowISO,
    fanout_state: "not_requested",
    fanout_attempt_count: 0,
    fanout_phase: "enqueue",
    fanout_cursor_registration_id: "",
    fanout_enqueued_count: 0,
    fanout_sweep_failed: false,
    fanout_verify_failure_passes: 0,
    fanout_last_failed_registration_id: "",
    fanout_lease_token: "",
    fanout_lease_until: nowISO,
    fanout_revision: randomUUID(),
    created_at: nowISO,
    updated_at: nowISO,
  });
  const stable = canonicalCheckpoint(
    await checkpointRows(input.store, input.status),
  ) || created;
  if (!clean(stable?.id)) {
    throw new Error("room_reconciliation_checkpoint_unconfirmed");
  }
  return {
    record: stable,
    cursor: clean(stable.fanout_cursor_registration_id),
  };
}

export async function advanceRoomReconciliationCheckpoint(input: {
  store: any;
  status: ReconciledRoomStatus;
  checkpoint: RoomReconciliationCheckpoint;
  cursor: string;
  now?: Date;
  randomUUID?: () => string;
}): Promise<boolean> {
  const id = clean(input.checkpoint.record?.id);
  const revision = clean(input.checkpoint.record?.fanout_revision);
  if (!id || !revision) return false;
  const nowISO = (input.now || new Date()).toISOString();
  const nextRevision = (input.randomUUID || (() => crypto.randomUUID()))();
  try {
    const result = await input.store.updateMany({
      id,
      dedupe_key: checkpointKey(input.status),
      status: "withdrawn",
      fanout_revision: revision,
    }, {
      $set: {
        fanout_cursor_registration_id: clean(input.cursor),
        fanout_revision: nextRevision,
        updated_at: nowISO,
      },
    });
    if (Number(result?.updated) === 1) return true;
  } catch {
    // A lost update response is reconciled by the exact re-read below.
  }
  const current = canonicalCheckpoint(
    await checkpointRows(input.store, input.status),
  );
  return clean(current?.fanout_revision) === nextRevision &&
    clean(current?.fanout_cursor_registration_id) === clean(input.cursor);
}

export async function loadRoomReconciliationPage(input: {
  roomStore: any;
  status: ReconciledRoomStatus;
  cursor: string;
  limit: number;
}): Promise<RoomReconciliationPage> {
  const limit = Math.min(24, Math.max(1, Math.floor(input.limit) || 1));
  const cursor = clean(input.cursor);
  const page: Entity[] = await input.roomStore.filter(
    {
      status: input.status,
      ...(cursor ? { id: { $gt: cursor } } : {}),
    },
    "id",
    limit,
    0,
  ) || [];
  if (page.length || !cursor) return { rooms: page, wrapped: false };

  const wrapped: Entity[] = await input.roomStore.filter(
    { status: input.status },
    "id",
    limit,
    0,
  ) || [];
  return { rooms: wrapped, wrapped: true };
}

function interleaveUniqueCandidates(
  sources: readonly ScheduledRoomReconciliationCandidate[][],
  limit: number,
): ScheduledRoomReconciliationCandidate[] {
  const selected: ScheduledRoomReconciliationCandidate[] = [];
  const seen = new Set<string>();
  const cursors = sources.map(() => 0);
  for (;;) {
    let progressed = false;
    for (let sourceIndex = 0; sourceIndex < sources.length; sourceIndex += 1) {
      const source = sources[sourceIndex];
      while (cursors[sourceIndex] < source.length) {
        const candidate = source[cursors[sourceIndex]];
        cursors[sourceIndex] += 1;
        const id = clean(candidate.room?.id);
        if (!id || seen.has(id)) continue;
        seen.add(id);
        selected.push(candidate);
        progressed = true;
        break;
      }
      if (selected.length >= limit) return selected;
    }
    if (!progressed) return selected;
  }
}

function candidates(
  rooms: readonly Entity[],
  status: ReconciledRoomStatus,
  source: "cursor" | "newest",
): ScheduledRoomReconciliationCandidate[] {
  return rooms.map((room) => ({ room, status, source }));
}

export function selectScheduledRoomReconciliationRooms(input: {
  finishedNewest: readonly Entity[];
  finishedCursorPage: readonly Entity[];
  playingNewest: readonly Entity[];
  playingCursorPage: readonly Entity[];
}): ScheduledRoomReconciliationCandidate[] {
  // Six durable-cursor terminal rooms plus two newest rooms keep both deep
  // fairness and prompt convergence. Playing gets the equivalent 3 + 1 split.
  const finished = interleaveUniqueCandidates([
    candidates(input.finishedCursorPage.slice(0, 6), "finished", "cursor"),
    candidates(input.finishedNewest.slice(0, 2), "finished", "newest"),
  ], 8);
  const playing = interleaveUniqueCandidates([
    candidates(input.playingCursorPage.slice(0, 3), "playing", "cursor"),
    candidates(input.playingNewest.slice(0, 1), "playing", "newest"),
  ], 4);
  const selected: ScheduledRoomReconciliationCandidate[] = [];
  let finishedIndex = 0;
  let playingIndex = 0;
  while (finishedIndex < finished.length || playingIndex < playing.length) {
    for (let count = 0; count < 2 && finishedIndex < finished.length; count++) {
      selected.push(finished[finishedIndex]);
      finishedIndex += 1;
    }
    if (playingIndex < playing.length) {
      selected.push(playing[playingIndex]);
      playingIndex += 1;
    }
  }
  return selected;
}

export function cursorAfterAttemptedRoomPage(input: {
  previousCursor: string;
  page: readonly Entity[];
  attemptedRoomIDs: ReadonlySet<string>;
}): string {
  let cursor = clean(input.previousCursor);
  for (const room of input.page) {
    const id = clean(room?.id);
    if (!id || !input.attemptedRoomIDs.has(id)) break;
    cursor = id;
  }
  return cursor;
}
