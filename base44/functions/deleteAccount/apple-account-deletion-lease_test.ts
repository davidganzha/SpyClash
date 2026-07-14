import {
  acquireAppleAccountDeletionLeases,
  AppleAccountDeletionLeaseError,
  commitAppleAccountDeletionLeases,
  releaseAppleAccountDeletionLeases,
} from "./apple-account-deletion-lease.ts";

type RecordValue = Record<string, any>;

const NOW = new Date("2026-07-14T12:00:00.000Z");
const TOKEN_A = "11111111-1111-4111-8111-111111111111";
const TOKEN_B = "22222222-2222-4222-8222-222222222222";
const TOMBSTONE = `deleted:${"a".repeat(40)}`;

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function account(
  id: string,
  token: string,
  userID = "user-1",
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
  contendIDs = new Set<string>();
  updateManyCalls: Array<{
    filter: RecordValue;
    update: RecordValue;
  }> = [];

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

  async updateMany(filter: RecordValue, update: RecordValue) {
    this.updateManyCalls.push({
      filter: structuredClone(filter),
      update: structuredClone(update),
    });
    if (this.contendIDs.delete(String(filter.id || ""))) {
      return { updated: 0 };
    }
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        updated += 1;
      }
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

Deno.test("account deletion refuses an active canonical Apple lease", async () => {
  const store = new MockAccountStore([
    account(
      "canonical",
      TOKEN_A,
      "user-1",
      "2026-01-01T00:00:00.000Z",
      "2026-07-14T12:10:00.000Z",
    ),
  ]);

  await expectLeaseError(
    () => acquireAppleAccountDeletionLeases(store, "user-1", NOW),
    "active_lease",
  );
  assert(store.updateManyCalls.length === 0, "active lease was overwritten");
});

Deno.test("account deletion rejects mixed owners for one Apple token", async () => {
  const store = new MockAccountStore([
    account("canonical", TOKEN_A),
    account(
      "foreign",
      TOKEN_A,
      "user-2",
      "2026-02-01T00:00:00.000Z",
    ),
  ]);

  await expectLeaseError(
    () => acquireAppleAccountDeletionLeases(store, "user-1", NOW),
    "mixed_owners",
  );
  assert(store.updateManyCalls.length === 0, "mixed ownership was mutated");
});

Deno.test("account deletion detects canonical Apple lease CAS contention", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  store.contendIDs.add("canonical");

  await expectLeaseError(
    () => acquireAppleAccountDeletionLeases(store, "user-1", NOW),
    "cas_contention",
  );
  assert(
    store.record("canonical").last_used_at ===
      "2026-07-14T11:00:00.000Z",
    "failed CAS changed the canonical record",
  );
});

Deno.test("successful deletion commits and releases the canonical Apple lease with CAS", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    "user-1",
    NOW,
  );
  const commitAt = new Date("2026-07-14T12:00:10.000Z");
  await commitAppleAccountDeletionLeases(
    store,
    leases,
    TOMBSTONE,
    commitAt,
  );

  assert(
    store.record("canonical").user_id === TOMBSTONE,
    "canonical owner was not tombstoned",
  );
  assert(
    store.record("canonical").last_used_at === commitAt.toISOString(),
    "canonical lease was not released at commit",
  );
  const commitCall = store.updateManyCalls.at(-1);
  assert(
    commitCall?.filter.id === "canonical" &&
      commitCall.filter.user_id === "user-1" &&
      commitCall.filter.last_used_at === leases[0].leaseUntil,
    "commit did not CAS every canonical lease field",
  );
});

Deno.test("billing rollback releases the canonical Apple lease without changing its owner", async () => {
  const store = new MockAccountStore([account("canonical", TOKEN_A)]);
  const leases = await acquireAppleAccountDeletionLeases(
    store,
    "user-1",
    NOW,
  );
  const rollbackAt = new Date("2026-07-14T12:00:20.000Z");
  await releaseAppleAccountDeletionLeases(store, leases, rollbackAt);

  assert(
    store.record("canonical").user_id === "user-1",
    "rollback changed the canonical owner",
  );
  assert(
    store.record("canonical").last_used_at === rollbackAt.toISOString(),
    "rollback did not release the canonical lease",
  );
  const rollbackCall = store.updateManyCalls.at(-1);
  assert(
    rollbackCall?.filter.id === "canonical" &&
      rollbackCall.filter.user_id === "user-1" &&
      rollbackCall.filter.last_used_at === leases[0].leaseUntil,
    "rollback did not use the canonical CAS lease",
  );
});

Deno.test("multi-token deletion leases deterministic canonical rows", async () => {
  const store = new MockAccountStore([
    account(
      "token-b-newer",
      TOKEN_B,
      "user-1",
      "2026-02-01T00:00:00.000Z",
    ),
    account(
      "token-a-newer",
      TOKEN_A,
      "user-1",
      "2026-03-01T00:00:00.000Z",
    ),
    account(
      "token-a-canonical",
      TOKEN_A,
      "user-1",
      "2026-01-01T00:00:00.000Z",
    ),
    account(
      "token-b-canonical",
      TOKEN_B,
      "user-1",
      "2026-01-01T00:00:00.000Z",
    ),
  ]);

  const leases = await acquireAppleAccountDeletionLeases(
    store,
    "user-1",
    NOW,
  );
  assert(leases.length === 2, "not every Apple token was leased");
  assert(
    leases.map((lease) => lease.appAccountToken).join(",") ===
      `${TOKEN_A},${TOKEN_B}`,
    "tokens were not acquired in deterministic order",
  );
  assert(
    leases.map((lease) => lease.accountID).join(",") ===
      "token-a-canonical,token-b-canonical",
    "canonical records were not selected deterministically",
  );
  assert(
    store.record("token-a-newer").last_used_at ===
      "2026-07-14T11:00:00.000Z",
    "noncanonical record was leased",
  );
});

Deno.test("failed multi-token acquisition rolls back earlier canonical leases", async () => {
  const store = new MockAccountStore([
    account("token-a", TOKEN_A),
    account(
      "token-b",
      TOKEN_B,
      "user-1",
      "2026-01-01T00:00:00.000Z",
      "2026-07-14T12:10:00.000Z",
    ),
  ]);

  await expectLeaseError(
    () => acquireAppleAccountDeletionLeases(store, "user-1", NOW),
    "active_lease",
  );
  assert(
    store.record("token-a").user_id === "user-1" &&
      store.record("token-a").last_used_at === NOW.toISOString(),
    "earlier canonical lease was not rolled back",
  );
});
