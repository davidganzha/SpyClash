import { assertEquals } from "jsr:@std/assert@1";
import { withGenerationWriterLease } from "../generateWordPack/generation-write-lifecycle.ts";
import { withWordPackWriterLease } from "../wordPackAction/word-pack-write-lifecycle.ts";
import { fanoutGameRoomSignalsBestEffort } from "./game-room-signal.ts";
import { runPostLeaseSignalWithinDeadline } from "./post-lease-signal.ts";
import { withRoomWriteLeases } from "./room-write-lifecycle.ts";

type Row = Record<string, any>;

class LifecycleStore {
  rows: Row[] = [];

  filter(query: Row, _sort: string, limit: number, offset: number) {
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ).slice(offset, offset + limit).map((row) => structuredClone(row)),
    );
  }

  create(value: Row) {
    const row = {
      ...structuredClone(value),
      id: `lifecycle-${this.rows.length + 1}`,
      created_date: new Date().toISOString(),
      updated_date: new Date().toISOString(),
    };
    this.rows.push(row);
    return Promise.resolve(structuredClone(row));
  }

  updateMany(query: Row, update: Row) {
    let updated = 0;
    for (const row of this.rows) {
      if (Object.entries(query).every(([key, value]) => row[key] === value)) {
        Object.assign(row, update.$set);
        updated += 1;
      }
    }
    return Promise.resolve({ updated });
  }
}

Deno.test("slow lobby signal releases the host before subsequent lobby, generation and pack writes", async () => {
  const lifecycleStore = new LifecycleStore();
  let epoch = 0;
  let signalCreates = 0;
  const outcome = await runPostLeaseSignalWithinDeadline({
    timeoutMS: 600,
    nowEpochMS: () => epoch,
    leasedOperation: (budget) =>
      withRoomWriteLeases({
        lifecycleStore,
        userIDs: ["host"],
        attempts: 1,
        action: async () => {
          const result = await fanoutGameRoomSignalsBestEffort({
            room: { id: "room", participant_user_ids: ["host"] },
            store: {
              filter: () => {
                epoch = 601;
                return Promise.resolve([]);
              },
              create: () => {
                signalCreates += 1;
                return Promise.resolve({});
              },
              update: () => Promise.resolve({}),
            },
            beforeOperation: budget.assertCanStart,
          });
          return result.failed === 0;
        },
      }),
  });
  assertEquals(outcome, false);
  assertEquals(signalCreates, 0);
  assertEquals(
    lifecycleStore.rows[0].lease_token.startsWith("released:"),
    true,
  );

  const actions: string[] = [];
  await withRoomWriteLeases({
    lifecycleStore,
    userIDs: ["host", "joiner"],
    attempts: 1,
    action: () => {
      actions.push("join");
      return Promise.resolve();
    },
  });
  await withGenerationWriterLease({
    lifecycleStore,
    userID: "host",
    action: (guard) =>
      guard.boundary(() => {
        actions.push("generate");
        return Promise.resolve();
      }),
  });
  await withWordPackWriterLease({
    lifecycleStore,
    userID: "host",
    attempts: 1,
    action: () => {
      actions.push("save-pack");
      return Promise.resolve();
    },
  });
  assertEquals(actions, ["join", "generate", "save-pack"]);
  assertEquals(
    lifecycleStore.rows.every((row) => row.lease_token.startsWith("released:")),
    true,
  );
});

Deno.test("failed duplicate signal update waits for its sibling before releasing host lease", async () => {
  const lifecycleStore = new LifecycleStore();
  let finish!: () => void;
  const gate = new Promise<void>((resolve) => {
    finish = resolve;
  });
  let writesStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    writesStarted = resolve;
  });
  let responseSent = false;
  const response = runPostLeaseSignalWithinDeadline({
    timeoutMS: 60_000,
    leasedOperation: (budget) =>
      withRoomWriteLeases({
        lifecycleStore,
        userIDs: ["host"],
        attempts: 1,
        action: async () => {
          const result = await fanoutGameRoomSignalsBestEffort({
            room: {
              id: "room",
              room_revision: 2,
              participant_user_ids: ["host"],
            },
            store: {
              filter: () =>
                Promise.resolve(["failed", "slow"].map((id) => ({
                  id,
                  room_id: "room",
                  user_id: "host",
                  room_revision: 1,
                }))),
              create: () => Promise.resolve({}),
              update: async (id) => {
                if (id === "failed") throw new Error("update failed");
                writesStarted();
                await gate;
              },
            },
            beforeOperation: budget.assertCanStart,
          });
          return result.failed === 0;
        },
      }),
  }).then((result) => {
    responseSent = true;
    return result;
  });
  await started;
  await Promise.resolve();
  await Promise.resolve();
  assertEquals(responseSent, false);
  assertEquals(lifecycleStore.rows[0].lease_token.startsWith("active:"), true);
  finish();
  assertEquals(await response, false);
  assertEquals(
    lifecycleStore.rows[0].lease_token.startsWith("released:"),
    true,
  );
});
