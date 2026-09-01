import { assertEquals } from "jsr:@std/assert@1";
import {
  advanceRoomReconciliationCheckpoint,
  cursorAfterAttemptedRoomPage,
  ensureRoomReconciliationCheckpoint,
  loadRoomReconciliationPage,
  selectScheduledRoomReconciliationRooms,
} from "./scheduled-room-reconciliation.ts";

function rooms(prefix: string, count: number, status = "finished") {
  return Array.from({ length: count }, (_, index) => ({
    id: `${prefix}-${String(index).padStart(3, "0")}`,
    status,
  }));
}

class RoomStore {
  constructor(readonly records: Record<string, any>[]) {}

  async filter(
    filter: Record<string, any>,
    order: string,
    limit: number,
  ) {
    const rows = this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => {
        if (key === "id" && value?.$gt !== undefined) {
          return record.id > value.$gt;
        }
        return record[key] === value;
      })
    );
    return [...rows].sort((left, right) =>
      order === "id" ? left.id.localeCompare(right.id) : 0
    ).slice(0, limit);
  }
}

class CheckpointStore {
  records: Record<string, any>[] = [];
  updateResponseLost = false;

  async filter(filter: Record<string, any>) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    );
  }

  async create(record: Record<string, any>) {
    const created = { id: `checkpoint-${this.records.length + 1}`, ...record };
    this.records.push(created);
    return created;
  }

  async updateMany(filter: Record<string, any>, update: Record<string, any>) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) return record;
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    if (updated && this.updateResponseLost) {
      this.updateResponseLost = false;
      throw new Error("lost update response");
    }
    return { updated };
  }
}

Deno.test("durable keyset cursor reaches rooms beyond 100 and wraps to the start", async () => {
  const roomStore = new RoomStore(rooms("finished", 125));
  const checkpointStore = new CheckpointStore();
  const seen = new Set<string>();
  let wrapped = false;

  for (let pass = 0; pass < 22; pass += 1) {
    const checkpoint = await ensureRoomReconciliationCheckpoint({
      store: checkpointStore,
      status: "finished",
      randomUUID: () => `revision-${pass}`,
      now: new Date("2026-09-01T00:00:00.000Z"),
    });
    const page = await loadRoomReconciliationPage({
      roomStore,
      status: "finished",
      cursor: checkpoint.cursor,
      limit: 6,
    });
    page.rooms.forEach((room) => seen.add(room.id));
    wrapped ||= page.wrapped;
    const attempted = new Set(page.rooms.map((room) => room.id));
    const nextCursor = cursorAfterAttemptedRoomPage({
      previousCursor: checkpoint.cursor,
      page: page.rooms,
      attemptedRoomIDs: attempted,
    });
    assertEquals(
      await advanceRoomReconciliationCheckpoint({
        store: checkpointStore,
        status: "finished",
        checkpoint,
        cursor: nextCursor,
        randomUUID: () => `advanced-${pass}`,
        now: new Date("2026-09-01T00:00:01.000Z"),
      }),
      true,
    );
  }

  assertEquals(seen.has("finished-124"), true);
  assertEquals(wrapped, true);
  assertEquals(seen.size, 125);
  assertEquals(
    checkpointStore.records[0].fanout_cursor_registration_id,
    "finished-005",
  );
  assertEquals(checkpointStore.records[0].status, "withdrawn");
});

Deno.test("checkpoint CAS reconciles a lost successful update response", async () => {
  const store = new CheckpointStore();
  const checkpoint = await ensureRoomReconciliationCheckpoint({
    store,
    status: "playing",
    randomUUID: () => "initial",
  });
  store.updateResponseLost = true;
  assertEquals(
    await advanceRoomReconciliationCheckpoint({
      store,
      status: "playing",
      checkpoint,
      cursor: "playing-099",
      randomUUID: () => "advanced",
    }),
    true,
  );
  assertEquals(store.records[0].fanout_cursor_registration_id, "playing-099");
});

Deno.test("selection keeps durable cursor pages and newest room heads", () => {
  const selected = selectScheduledRoomReconciliationRooms({
    finishedNewest: [{ id: "finished-new" }, { id: "finished-second" }],
    finishedCursorPage: rooms("finished-old", 6),
    playingNewest: [{ id: "playing-new" }, { id: "playing-second" }],
    playingCursorPage: rooms("playing-old", 3, "playing"),
  });

  assertEquals(selected.length, 12);
  assertEquals(selected.map((candidate) => candidate.room.id), [
    "finished-old-000",
    "finished-new",
    "playing-old-000",
    "finished-old-001",
    "finished-second",
    "playing-new",
    "finished-old-002",
    "finished-old-003",
    "playing-old-001",
    "finished-old-004",
    "finished-old-005",
    "playing-old-002",
  ]);
  assertEquals(
    selected.filter((candidate) => candidate.source === "cursor").length,
    9,
  );
});

Deno.test("cursor advances only through the contiguous attempted prefix", () => {
  const page = rooms("finished", 6);
  assertEquals(
    cursorAfterAttemptedRoomPage({
      previousCursor: "finished-previous",
      page,
      attemptedRoomIDs: new Set([
        "finished-000",
        "finished-001",
        "finished-003",
      ]),
    }),
    "finished-001",
  );
});
