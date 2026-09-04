import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  fanoutProfileUpdate,
  type ProfileSignalWriteLeaseRunner,
} from "./profile-signal.ts";

type Entity = Record<string, unknown>;

class Store {
  listCalls = 0;
  filterCalls = 0;
  creates: Entity[] = [];
  updates: Array<{ id: string; value: Entity }> = [];
  writeAttempts = new Map<string, number>();
  failuresRemaining = new Map<string, number>();
  loseCreateResponseFor = new Set<string>();
  nextID = 1;

  constructor(public rows: Entity[]) {
    this.rows = structuredClone(rows);
  }

  list(_sort: string, limit: number, skip: number) {
    this.listCalls += 1;
    return Promise.resolve(
      this.rows.slice(skip, skip + limit).map((row) => structuredClone(row)),
    );
  }

  filter(query: Record<string, unknown>) {
    this.filterCalls += 1;
    return Promise.resolve(
      this.rows.filter((row) =>
        Object.entries(query).every(([key, value]) => row[key] === value)
      ).map((row) => structuredClone(row)),
    );
  }

  private failIfNeeded(value: Entity) {
    const recipientUserID = String(value.recipient_user_id || "");
    this.writeAttempts.set(
      recipientUserID,
      (this.writeAttempts.get(recipientUserID) || 0) + 1,
    );
    const remaining = this.failuresRemaining.get(recipientUserID) || 0;
    if (remaining > 0) {
      this.failuresRemaining.set(recipientUserID, remaining - 1);
      throw new Error("signal unavailable");
    }
  }

  create(value: Entity) {
    try {
      this.failIfNeeded(value);
    } catch (error) {
      return Promise.reject(error);
    }
    const row = { id: `signal-${this.nextID++}`, ...structuredClone(value) };
    this.rows.push(row);
    this.creates.push(structuredClone(value));
    const recipientUserID = String(value.recipient_user_id || "");
    if (this.loseCreateResponseFor.delete(recipientUserID)) {
      return Promise.reject(new Error("create response lost"));
    }
    return Promise.resolve(structuredClone(row));
  }

  update(id: string, value: Entity) {
    try {
      this.failIfNeeded(value);
    } catch (error) {
      return Promise.reject(error);
    }
    const index = this.rows.findIndex((row) => row.id === id);
    if (index < 0) return Promise.reject(new Error("missing"));
    this.rows[index] = { ...this.rows[index], ...structuredClone(value) };
    this.updates.push({ id, value: structuredClone(value) });
    return Promise.resolve(structuredClone(this.rows[index]));
  }
}

function passthroughLeaseRunner(
  scopes?: string[][],
): ProfileSignalWriteLeaseRunner {
  return async ({ userIDs, action }) => {
    scopes?.push(userIDs.map(String));
    await action({ persist: (writer) => writer() });
  };
}

Deno.test("profile signal fanout performs one audience read and protects every raw identity", async () => {
  const users = new Store([
    { id: "user-a" },
    { id: "user-b" },
    { id: "user-c" },
  ]);
  const signals = new Store([{
    id: "signal-b",
    recipient_user_id: "user-b",
    profile_user_id: "old-profile",
    revision: 1,
  }]);
  const scopes: string[][] = [];

  const result = await fanoutProfileUpdate({
    userStore: users,
    signalStore: signals,
    profileUserID: "profile-owner",
    revision: 42,
    runWithWriteLeases: passthroughLeaseRunner(scopes),
  });

  assertEquals(result, {
    attempted: 3,
    succeeded: 3,
    failed: 0,
    failedRecipientUserIDs: [],
  });
  assertEquals(users.listCalls, 1);
  assertEquals(signals.listCalls, 1);
  assertEquals(scopes, [["profile-owner", "user-a", "user-b", "user-c"]]);
  assertEquals(signals.updates, [{
    id: "signal-b",
    value: {
      recipient_user_id: "user-b",
      profile_user_id: "profile-owner",
      revision: 42,
    },
  }]);
  assertEquals(
    signals.creates.map((signal) => signal.recipient_user_id).sort(),
    ["user-a", "user-c"],
  );
});

Deno.test("one permanent write failure never starves its batch or later batches", async () => {
  const users = new Store(
    ["a", "b", "c", "d", "e", "f"].map((id) => ({ id: `user-${id}` })),
  );
  const signals = new Store([]);
  signals.failuresRemaining.set("user-b", 100);
  const delays: number[] = [];
  const logged: string[] = [];

  const result = await fanoutProfileUpdate({
    userStore: users,
    signalStore: signals,
    profileUserID: "profile-owner",
    revision: 43,
    runWithWriteLeases: passthroughLeaseRunner(),
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    logError: (message) => logged.push(message),
  });

  assertEquals(result, {
    attempted: 6,
    succeeded: 5,
    failed: 1,
    failedRecipientUserIDs: ["user-b"],
  });
  assertEquals(delays, [75, 225]);
  assertEquals(logged, ["community profile signal fanout deferred"]);
  assertEquals(
    signals.rows.map((row) => row.recipient_user_id).sort(),
    ["user-a", "user-c", "user-d", "user-e", "user-f"],
  );
  assertEquals(signals.writeAttempts.get("user-b"), 3);
});

Deno.test("profile fanout retries a transient failure and reconciles a lost create response", async () => {
  const users = new Store([{ id: "user-a" }, { id: "user-b" }]);
  const signals = new Store([]);
  signals.failuresRemaining.set("user-a", 1);
  signals.loseCreateResponseFor.add("user-b");
  const delays: number[] = [];

  const result = await fanoutProfileUpdate({
    userStore: users,
    signalStore: signals,
    profileUserID: "profile-owner",
    revision: 44,
    runWithWriteLeases: passthroughLeaseRunner(),
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
  });

  assertEquals(result.failed, 0);
  assertEquals(delays, [75]);
  assertEquals(signals.rows.length, 2);
  assertEquals(
    signals.rows.map((row) => row.recipient_user_id).sort(),
    ["user-a", "user-b"],
  );
  assert(
    signals.updates.some((write) => write.value.recipient_user_id === "user-b"),
  );
});

Deno.test("a deleting recipient is isolated with singleton lease retries", async () => {
  const users = new Store(
    ["a", "deleting", "c", "d", "e"].map((id) => ({ id: `user-${id}` })),
  );
  const signals = new Store([]);
  const scopes: string[][] = [];
  const runWithWriteLeases: ProfileSignalWriteLeaseRunner = async (scope) => {
    const userIDs = scope.userIDs.map(String);
    scopes.push(userIDs);
    if (userIDs.includes("user-deleting")) {
      throw new Error("deletion in progress");
    }
    await scope.action({ persist: (writer) => writer() });
  };

  const result = await fanoutProfileUpdate({
    userStore: users,
    signalStore: signals,
    profileUserID: "profile-owner",
    revision: 45,
    runWithWriteLeases,
    delay: () => Promise.resolve(),
  });

  assertEquals(result.failedRecipientUserIDs, ["user-deleting"]);
  assertEquals(
    signals.rows.map((row) => row.recipient_user_id).sort(),
    ["user-a", "user-c", "user-d", "user-e"],
  );
  assert(scopes.every((scope) => scope.includes("profile-owner")));
  assert(
    scopes.some((scope) => scope.length === 2 && scope.includes("user-a")),
  );
  assert(
    scopes.some((scope) =>
      scope.length === 2 && scope.includes("user-deleting")
    ),
  );
});
