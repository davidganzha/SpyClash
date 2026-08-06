import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  isRoomWriteCASConflict,
  roomWriteRevision,
  writeRoomWithCAS,
} from "./room-write-cas.ts";

class MemoryRoomStore {
  room: Record<string, any>;
  failAfterCommit = false;

  constructor(room: Record<string, any>) {
    this.room = { ...room };
  }

  async updateMany(
    filter: Record<string, unknown>,
    update: Record<string, any>,
  ) {
    if (
      this.room.id !== filter.id ||
      this.room.room_revision !== filter.room_revision
    ) return { updated: 0 };
    this.room = { ...this.room, ...(update.$set || {}) };
    if (this.failAfterCommit) throw new Error("response lost");
    return { updated: 1 };
  }
}

Deno.test("room CAS commits one monotonic revision without a post-write read", async () => {
  const store = new MemoryRoomStore({ id: "room-1", room_revision: 4 });
  let reads = 0;
  const result = await writeRoomWithCAS({
    store,
    room: store.room,
    patch: { question_phase: "asking" },
    read: () => {
      reads += 1;
      return Promise.resolve(store.room);
    },
    randomUUID: () => "write-5",
  });

  assertEquals(result.room_revision, 5);
  assertEquals(result.question_phase, "asking");
  assertEquals(store.room.room_last_write_token, "write-5");
  assertEquals(reads, 0);
});

Deno.test("room CAS rejects a stale writer with a typed retryable conflict", async () => {
  const store = new MemoryRoomStore({ id: "room-1", room_revision: 5 });
  const error = await assertRejects(() =>
    writeRoomWithCAS({
      store,
      room: { id: "room-1", room_revision: 4 },
      patch: { question_phase: "asking" },
    })
  );
  assertEquals(isRoomWriteCASConflict(error), true);
  assertEquals((error as any).retryable, true);
});

Deno.test("room CAS reconciles a response-lost committed write by token", async () => {
  const store = new MemoryRoomStore({ id: "room-1", room_revision: 2 });
  store.failAfterCommit = true;
  const result = await writeRoomWithCAS({
    store,
    room: store.room,
    patch: { current_asker_email: "next@example.com" },
    read: () => Promise.resolve(store.room),
    randomUUID: () => "write-3",
  });

  assertEquals(result.room_revision, 3);
  assertEquals(result.current_asker_email, "next@example.com");
});

Deno.test("legacy rooms are kept off the unleased fast path", () => {
  assertEquals(roomWriteRevision({ id: "legacy" }), null);
  assertEquals(roomWriteRevision({ id: "current", room_revision: 0 }), 0);
});
