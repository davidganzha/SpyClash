import {
  acquireAppleAccountDeletionLeases,
  AppleAccountDeletionLeaseError,
  precommitAppleAccountDeletionLeases,
  releasePrecommittedAppleAccountLeasesBestEffort,
  renewAppleAccountDeletionLeases,
  rollbackAppleAccountDeletionLeases,
} from "./apple-account-deletion-lease.ts";

type RecordValue = Record<string, any>;

const NOW = new Date("2026-07-14T12:00:00.000Z");
const TOKEN_A = "11111111-1111-4111-8111-111111111111";
const TOKEN_B = "22222222-2222-4222-8222-222222222222";
const USER_ID = "user-1";
const TOMBSTONE = `deleted:${"a".repeat(40)}`;

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function account(
  id: string,
  token: string,
  userID = USER_ID,
  createdDate = "2026-01-01T00:00:00.000Z",
  lastUsedAt = "2026-07-14T11:00:00.000Z",
): RecordValue {
  return {
    id,
    user_id: userID,
    app_account_token: token,
    created_date: createdDate,
    created_at: createdDate,
    last_used_at: lastUsedAt,
  };
}

class MockAccountStore {
  records: RecordValue[];
  updateManyCalls: Array<{ filter: RecordValue; update: RecordValue }> = [];
  createCalls: RecordValue[] = [];
  updateManyHook?: (
    filter: RecordValue,
    update: RecordValue,
  ) => "zero" | "throw_after_apply" | undefined;
  createHook?: (created: RecordValue, store: MockAccountStore) => void;

  constructor(records: RecordValue[]) {
    this.records = structuredClone(records);
  }

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .sort((left, right) =>
        String(left.created_date || "").localeCompare(
          String(right.created_date || ""),
        ) || String(left.id || "").localeCompare(String(right.id || ""))
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `created-${this.createCalls.length + 1}`,
      created_date: `2026-07-14T12:00:00.${
        String(this.createCalls.length + 1).padStart(3, "0")
      }Z`,
    };
    this.records.push(created);
    this.createCalls.push(structuredClone(created));
    this.createHook?.(created, this);
    return structuredClone(created);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    this.updateManyCalls.push({
      filter: structuredClone(filter),
      update: structuredClone(update),
    });
    const hookResult = this.updateManyHook?.(filter, update);
    if (hookResult === "zero") return { updated: 0 };

    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        updated += 1;
      }
    }
    if (hookResult === "throw_after_apply") {
      throw new Error("simulated response loss");
    }
    return { updated };
  }

  record(id: string) {
    const value = this.records.find((record) => record.id === id);
    if (!value) throw new Error(`Missing mock record ${id}`);
    return value;
  }
}

async function expectLeaseError(
  action: () => Promise<unknown>,
  code: AppleAccountDeletionLeaseError["code"],
) {
  let caught: unknown;
  try {
    await action();
  } catch (error) {
    caught = error;
  }
  assert(
    caught instanceof AppleAccountDeletionLeaseError,
    `Expected AppleAccountDeletionLeaseError, received ${String(caught)}`,
  );
  assert(
    (caught as AppleAccountDeletionLeaseError).code === code,
    `Expected ${code}, received ${
      (caught as AppleAccountDeletionLeaseError).code
    }`,
  );
}

Deno.test("deletion preflight refuses an active canonical Apple lease", async () => {
  const store = new MockAccountStore([
    account(
      "canonical",
      TOKEN_A,
      USER_ID,
      "2026-01-01T00:00:00.000Z",
      "2026-07-14T12:10:00.000Z",
    ),
  ]);

  await expectLeaseError(
    () =>
      acquireAppleAccountDeletionLeases(
        store,
        USER_ID,
        TOMBSTONE,
        NOW,
      ),
    "active_lease",
  );
  assert(store.updateManyCalls.length === 0, "active lease was overwritten");
});

Deno.test("deletion preflight accepts only the live owner and its own tombstone", async () => {
  const resumable = new MockAccountStore([
    account("live", TOKEN_A),
    account(
      "partial-precommit",
      TOKEN_A,
      TOMBSTONE,
      "2026-02-01T00:00:00.000Z",
    ),
  ]);
  const leases = await acquireAppleAccountDeletionLeases(
    resumable,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  assert(leases.length === 1, "own partial precommit was not resumable");

  const foreign = new MockAccountStore([
    account("live", TOKEN_A),
    account(
      "foreign",
      TOKEN_A,
      "user-2",
      "2026-02-01T00:00:00.000Z",
    ),
  ]);
  await expectLeaseError(
    () =>
      acquireAppleAccountDeletionLeases(
        foreign,
        USER_ID,
        TOMBSTONE,
        NOW,
      ),
    "mixed_owners",
  );
});

Deno.test("deletion preflight detects canonical Apple lease CAS contention", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  store.updateManyHook = (filter) =>
    filter.id === "canonical" ? "zero" : undefined;

  await expectLeaseError(
    () =>
      acquireAppleAccountDeletionLeases(
        store,
        USER_ID,
        TOMBSTONE,
        NOW,
      ),
    "cas_contention",
  );
  assert(
    store.record("canonical").last_used_at ===
      "2026-07-14T11:00:00.000Z",
    "failed CAS changed the canonical record",
  );
});

Deno.test("deletion preflight reconciles a lease applied before response loss", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  let lost = false;
  store.updateManyHook = (_filter, update) => {
    if (lost || update.$set?.user_id || !update.$set?.last_used_at) return;
    lost = true;
    return "throw_after_apply";
  };

  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  assert(lost, "test did not lose the acquisition response");
  assert(leases.length === 1, "applied acquisition was not reconciled");
  assert(
    store.record("canonical").last_used_at === leases[0].leaseUntil,
    "reconciled acquisition does not match the durable lease",
  );
});

Deno.test("zero-binding deletion creates a future-leased real sentinel", async () => {
  const store = new MockAccountStore([]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
    () => TOKEN_A,
  );

  assert(store.createCalls.length === 1, "sentinel was not created");
  assert(leases.length === 1, "sentinel was not leased");
  assert(
    store.record("created-1").app_account_token === TOKEN_A &&
      store.record("created-1").user_id === USER_ID,
    "sentinel is not a normal user AppStoreAccount",
  );
  assert(
    Date.parse(store.record("created-1").last_used_at) > NOW.getTime(),
    "sentinel did not block concurrent prepare",
  );
});

Deno.test("zero-binding stabilization absorbs a prepare-created race token", async () => {
  const store = new MockAccountStore([]);
  store.createHook = (_sentinel, target) => {
    target.records.push(
      account(
        "prepare-race",
        TOKEN_B,
        USER_ID,
        "2026-07-14T12:00:00.002Z",
      ),
    );
  };

  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
    () => TOKEN_A,
  );
  assert(leases.length === 2, "prepare-created token escaped stabilization");
  assert(
    leases.map((lease) => lease.appAccountToken).join(",") ===
      `${TOKEN_A},${TOKEN_B}`,
    "race tokens were not stabilized deterministically",
  );
  assert(
    Date.parse(store.record("prepare-race").last_used_at) > NOW.getTime(),
    "prepare-created token was not leased",
  );
});

Deno.test("crash retry creates a live sentinel when only own tombstones remain", async () => {
  const store = new MockAccountStore([
    account("crashed-precommit", TOKEN_B, TOMBSTONE),
  ]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
    () => TOKEN_A,
  );

  assert(
    store.createCalls.length === 1,
    "retry did not create a live sentinel",
  );
  assert(
    leases.length === 2,
    "retry did not lease sentinel and tombstone token",
  );
  assert(
    store.record("created-1").user_id === USER_ID &&
      Date.parse(store.record("created-1").last_used_at) > NOW.getTime(),
    "retry sentinel cannot block reserveAccountToken's live-user query",
  );
});

Deno.test("held Apple deletion leases renew before billing redaction", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  const originalLeaseUntil = leases[0].leaseUntil;
  const renewedAt = new Date("2026-07-14T12:04:00.000Z");
  await renewAppleAccountDeletionLeases(
    store,
    leases,
    USER_ID,
    TOMBSTONE,
    renewedAt,
  );
  assert(
    leases[0].leaseUntil !== originalLeaseUntil &&
      store.record("canonical").last_used_at === leases[0].leaseUntil,
    "lease did not renew through its exact prior CAS timestamp",
  );
});

Deno.test("lease renewal reconciles an update applied before response loss", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  let lost = false;
  store.updateManyHook = (_filter, update) => {
    if (lost || update.$set?.user_id || !update.$set?.last_used_at) return;
    lost = true;
    return "throw_after_apply";
  };

  await renewAppleAccountDeletionLeases(
    store,
    leases,
    USER_ID,
    TOMBSTONE,
    new Date("2026-07-14T12:04:00.000Z"),
  );
  assert(lost, "test did not lose the renewal response");
  assert(
    store.record("canonical").last_used_at === leases[0].leaseUntil,
    "applied renewal was not reconciled into the in-memory lease",
  );
});

Deno.test("multi-token partial precommit remains rollback-safe before User.delete", async () => {
  const store = new MockAccountStore([
    account("token-a", TOKEN_A),
    account("token-b", TOKEN_B),
  ]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  store.updateManyHook = (filter, update) =>
    filter.id === "token-b" && update.$set?.user_id === TOMBSTONE
      ? "zero"
      : undefined;

  await expectLeaseError(
    () =>
      precommitAppleAccountDeletionLeases(
        store,
        leases,
        USER_ID,
        TOMBSTONE,
      ),
    "precommit_failed",
  );
  assert(
    store.record("token-a").user_id === TOMBSTONE &&
      store.record("token-b").user_id === USER_ID,
    "test did not produce a partial multi-token precommit",
  );

  store.updateManyHook = undefined;
  await rollbackAppleAccountDeletionLeases(
    store,
    leases,
    USER_ID,
    TOMBSTONE,
    new Date("2026-07-14T12:00:30.000Z"),
  );
  assert(
    store.record("token-a").user_id === USER_ID &&
      store.record("token-b").user_id === USER_ID,
    "partial precommit was not fully rolled back",
  );
});

Deno.test("rollback recovers a precommit applied before response loss", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  store.updateManyHook = (_filter, update) =>
    update.$set?.user_id === TOMBSTONE ? "throw_after_apply" : undefined;
  let failed = false;
  try {
    await precommitAppleAccountDeletionLeases(
      store,
      leases,
      USER_ID,
      TOMBSTONE,
    );
  } catch {
    failed = true;
  }
  assert(failed, "response-loss precommit unexpectedly succeeded");
  assert(
    store.record("canonical").user_id === TOMBSTONE,
    "simulated response loss did not apply the precommit",
  );

  store.updateManyHook = undefined;
  await rollbackAppleAccountDeletionLeases(
    store,
    leases,
    USER_ID,
    TOMBSTONE,
    new Date("2026-07-14T12:00:30.000Z"),
  );
  assert(
    store.record("canonical").user_id === USER_ID,
    "unknown precommit result was not recovered",
  );
});

Deno.test("successful precommit removes raw identity before best-effort release", async () => {
  const store = new MockAccountStore([
    account("token-b", TOKEN_B),
    account("token-a", TOKEN_A),
  ]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    USER_ID,
    TOMBSTONE,
    NOW,
  );
  await precommitAppleAccountDeletionLeases(
    store,
    leases,
    USER_ID,
    TOMBSTONE,
  );
  assert(
    store.records.every((record) => record.user_id === TOMBSTONE),
    "raw owner survived canonical precommit",
  );
  assert(
    store.records.every((record) =>
      Date.parse(record.last_used_at) > NOW.getTime()
    ),
    "precommit released a lease before User.delete",
  );

  const failures = await releasePrecommittedAppleAccountLeasesBestEffort(
    store,
    leases,
    TOMBSTONE,
    new Date("2026-07-14T12:00:30.000Z"),
  );
  assert(failures.length === 0, "safe post-delete release failed");
  assert(
    store.records.every((record) => record.user_id === TOMBSTONE),
    "post-delete release restored raw identity",
  );
});
