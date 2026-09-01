import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  type BackfillHistoryStore,
  decodeBackfillCursor,
  runCommunityProfileBackfillPage,
} from "./community-profile-backfill.ts";

type Entity = Record<string, unknown>;

class MemoryHistoryStore implements BackfillHistoryStore {
  constructor(public rows: Entity[]) {}

  filter(
    _query: Entity,
    _sort?: string,
    limit = 100,
    skip = 0,
  ) {
    return Promise.resolve(
      structuredClone(this.rows.slice(skip, skip + limit)),
    );
  }
}

function rows(): Entity[] {
  return [
    { id: "h1", player_user_id: "user-a" },
    { id: "h2", player_email: "legacy@example.com" },
    { id: "h3", player_user_id: "user-b" },
    { id: "h4", player_user_id: "user-a" },
  ];
}

Deno.test("backfill is dry-run and never links mutable email", async () => {
  const reconciled: string[] = [];
  const result = await runCommunityProfileBackfillPage({
    historyStore: new MemoryHistoryStore(rows()),
    batchSize: 3,
    apply: false,
    reconcileUser: (userID) => {
      reconciled.push(userID);
      return Promise.resolve();
    },
  });

  assertEquals(result.dry_run, true);
  assertEquals(result.player_user_ids, ["user-a", "user-b"]);
  assertEquals(result.reconciled_users, 0);
  assertEquals(reconciled, []);
  assertEquals(decodeBackfillCursor(result.next_cursor)?.offset, 3);
});

Deno.test("explicit apply resumes after a verified anchor and is retry-safe", async () => {
  const history = new MemoryHistoryStore(rows());
  const first = await runCommunityProfileBackfillPage({
    historyStore: history,
    batchSize: 2,
    apply: true,
    reconcileUser: () => Promise.resolve(),
  });
  const reconciled: string[] = [];
  const second = await runCommunityProfileBackfillPage({
    historyStore: history,
    cursor: first.next_cursor,
    batchSize: 2,
    apply: true,
    reconcileUser: (userID) => {
      reconciled.push(userID);
      return Promise.resolve();
    },
  });

  assertEquals(reconciled, ["user-a", "user-b"]);
  assertEquals(second.reconciled_users, 2);
  assertEquals(second.next_cursor, null);
});

Deno.test("resume fails closed if earlier history changed", async () => {
  const history = new MemoryHistoryStore(rows());
  const first = await runCommunityProfileBackfillPage({
    historyStore: history,
    batchSize: 2,
    apply: false,
    reconcileUser: () => Promise.resolve(),
  });
  history.rows.splice(0, 1);

  await assertRejects(
    () =>
      runCommunityProfileBackfillPage({
        historyStore: history,
        cursor: first.next_cursor,
        batchSize: 2,
        apply: false,
        reconcileUser: () => Promise.resolve(),
      }),
    Error,
    "invalid or stale",
  );
});

Deno.test("failed apply returns no advanced cursor and retry repeats absolute users", async () => {
  const history = new MemoryHistoryStore(rows());
  const attempts: string[] = [];
  await assertRejects(() =>
    runCommunityProfileBackfillPage({
      historyStore: history,
      batchSize: 4,
      apply: true,
      reconcileUser: (userID) => {
        attempts.push(userID);
        return userID === "user-b"
          ? Promise.reject(new Error("transient"))
          : Promise.resolve();
      },
    })
  );
  await runCommunityProfileBackfillPage({
    historyStore: history,
    batchSize: 4,
    apply: true,
    reconcileUser: (userID) => {
      attempts.push(userID);
      return Promise.resolve();
    },
  });

  assertEquals(attempts, ["user-a", "user-b", "user-a", "user-b"]);
});

Deno.test("function boundary is admin-only and requires explicit apply", async () => {
  const source = await Deno.readTextFile(new URL("./main.ts", import.meta.url));
  assertEquals(
    source.includes('clean(user.role).toLowerCase() !== "admin"'),
    true,
  );
  assertEquals(source.includes('const apply = backfillMode === "apply"'), true);
  assertEquals(source.includes("playerUserIDs: [userID]"), true);
  assertEquals(source.includes("withRoomWriteLeases({"), true);
});
