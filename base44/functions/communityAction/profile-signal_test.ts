import { assertEquals } from "jsr:@std/assert@1";
import { fanoutProfileUpdate } from "./profile-signal.ts";

type Entity = Record<string, unknown>;

class Store {
  listCalls = 0;
  creates: Entity[] = [];
  updates: Array<{ id: string; value: Entity }> = [];

  constructor(private readonly rows: Entity[]) {}

  list(_sort: string, limit: number, skip: number) {
    this.listCalls += 1;
    return Promise.resolve(
      this.rows.slice(skip, skip + limit).map((row) => structuredClone(row)),
    );
  }

  create(value: Entity) {
    this.creates.push(structuredClone(value));
    return Promise.resolve(value);
  }

  update(id: string, value: Entity) {
    this.updates.push({ id, value: structuredClone(value) });
    return Promise.resolve(value);
  }
}

Deno.test("profile signal fanout performs one audience read instead of one read per user", async () => {
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

  await fanoutProfileUpdate({
    userStore: users,
    signalStore: signals,
    profileUserID: "profile-owner",
    revision: 42,
  });

  assertEquals(users.listCalls, 1);
  assertEquals(signals.listCalls, 1);
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
