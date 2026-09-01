import { assertEquals } from "jsr:@std/assert@1";
import {
  type CommunityProfileSignalStore,
  fanoutCommunityProfileInvalidations,
} from "./community-profile-signal.ts";

type Entity = Record<string, unknown>;

class MemorySignalStore implements CommunityProfileSignalStore {
  rows: Entity[] = [];
  nextID = 1;
  filterCalls = 0;
  failRecipients = new Set<string>();
  failReadRecipients = new Set<string>();
  writes: Array<{
    kind: "create" | "update";
    recipientUserID: string;
    profileUserID: string;
    revision: number;
  }> = [];

  filter(query: Record<string, unknown>) {
    this.filterCalls += 1;
    const recipientUserID = String(query.recipient_user_id || "");
    if (this.failReadRecipients.has(recipientUserID)) {
      return Promise.reject(new Error("read unavailable"));
    }
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ),
    );
  }

  create(value: Entity) {
    const recipientUserID = String(value.recipient_user_id || "");
    if (this.failRecipients.has(recipientUserID)) {
      return Promise.reject(new Error("unavailable"));
    }
    const row = { id: `signal-${this.nextID++}`, ...value };
    this.rows.push(row);
    this.writes.push({
      kind: "create",
      recipientUserID,
      profileUserID: String(value.profile_user_id || ""),
      revision: Number(value.revision),
    });
    return Promise.resolve(row);
  }

  update(id: string, value: Entity) {
    const recipientUserID = String(value.recipient_user_id || "");
    if (this.failRecipients.has(recipientUserID)) {
      return Promise.reject(new Error("unavailable"));
    }
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing"));
    this.rows[index] = { ...this.rows[index], ...value };
    this.writes.push({
      kind: "update",
      recipientUserID,
      profileUserID: String(value.profile_user_id || ""),
      revision: Number(value.revision),
    });
    return Promise.resolve(this.rows[index]);
  }
}

Deno.test("finished participants receive every affected profile invalidation", async () => {
  const signals = new MemorySignalStore();
  signals.rows = [{
    id: "signal-a",
    recipient_user_id: "user-a",
    profile_user_id: "old-profile",
    revision: 1,
  }];

  const result = await fanoutCommunityProfileInvalidations({
    signalStore: signals,
    recipientUserIDs: ["user-a", "user-b", "user-a"],
    profileUserIDs: ["user-a", "user-b", "user-a"],
    revisionBase: 42,
  });

  assertEquals(result, { attempted: 4, succeeded: 4, failed: 0 });
  assertEquals(signals.filterCalls, 2);
  assertEquals(signals.writes, [
    {
      kind: "update",
      recipientUserID: "user-a",
      profileUserID: "user-a",
      revision: 42,
    },
    {
      kind: "create",
      recipientUserID: "user-b",
      profileUserID: "user-a",
      revision: 42,
    },
    {
      kind: "update",
      recipientUserID: "user-a",
      profileUserID: "user-b",
      revision: 43,
    },
    {
      kind: "update",
      recipientUserID: "user-b",
      profileUserID: "user-b",
      revision: 43,
    },
  ]);
  assertEquals(
    signals.rows.map((row) => ({
      recipient_user_id: row.recipient_user_id,
      profile_user_id: row.profile_user_id,
      revision: row.revision,
    })),
    [
      {
        recipient_user_id: "user-a",
        profile_user_id: "user-b",
        revision: 43,
      },
      {
        recipient_user_id: "user-b",
        profile_user_id: "user-b",
        revision: 43,
      },
    ],
  );
});

Deno.test("profile invalidation remains best effort for each recipient", async () => {
  const signals = new MemorySignalStore();
  signals.failRecipients.add("user-b");
  const errors: string[] = [];

  const result = await fanoutCommunityProfileInvalidations({
    signalStore: signals,
    recipientUserIDs: ["user-a", "user-b"],
    profileUserIDs: ["user-a", "user-b"],
    revisionBase: 100,
    logError: (message) => errors.push(message),
  });

  assertEquals(result, { attempted: 4, succeeded: 2, failed: 2 });
  assertEquals(errors, [
    "community profile signal fanout deferred",
    "community profile signal fanout deferred",
  ]);
  assertEquals(signals.rows.length, 1);
  assertEquals(signals.rows[0].recipient_user_id, "user-a");
  assertEquals(signals.rows[0].profile_user_id, "user-b");
});

Deno.test("profile invalidation isolates a recipient whose signal read fails", async () => {
  const signals = new MemorySignalStore();
  signals.failReadRecipients.add("user-b");
  const errors: string[] = [];

  const result = await fanoutCommunityProfileInvalidations({
    signalStore: signals,
    recipientUserIDs: ["user-a", "user-b"],
    profileUserIDs: ["user-a", "user-b"],
    revisionBase: 100,
    logError: (message) => errors.push(message),
  });

  assertEquals(result, { attempted: 4, succeeded: 2, failed: 2 });
  assertEquals(errors, ["community profile signal read deferred"]);
  assertEquals(signals.writes.map((write) => write.recipientUserID), [
    "user-a",
    "user-a",
  ]);
});

Deno.test("empty participant scope performs no signal-store reads", async () => {
  const signals = new MemorySignalStore();
  assertEquals(
    await fanoutCommunityProfileInvalidations({
      signalStore: signals,
      recipientUserIDs: [],
      profileUserIDs: ["user-a"],
    }),
    { attempted: 0, succeeded: 0, failed: 0 },
  );
  assertEquals(signals.filterCalls, 0);
});
