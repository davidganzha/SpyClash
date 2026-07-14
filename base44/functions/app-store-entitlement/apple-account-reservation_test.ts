import {
  AppleAccountReservationError,
  reserveAppleAccountToken,
} from "./apple-account-reservation.ts";
import { isAppleAccountLeaseActive } from "./apple-account-binding.ts";
import { deletedAccountTombstone } from "./deleted-account-identity.ts";
import {
  acquireAppleAccountDeletionLeases,
  AppleAccountDeletionLeaseError,
} from "./apple-account-deletion-lease.ts";

type RecordValue = Record<string, any>;

const USER_ID = "user-1";
const TOKEN_A = "11111111-1111-4111-8111-111111111111";
const TOKEN_B = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2026-07-14T12:00:00.000Z");

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function account(
  id: string,
  token: string,
  userID: string,
  lastUsedAt = "2026-07-14T11:00:00.000Z",
): RecordValue {
  return {
    id,
    user_id: userID,
    app_account_token: token,
    created_at: "2026-01-01T00:00:00.000Z",
    created_date: "2026-01-01T00:00:00.000Z",
    last_used_at: lastUsedAt,
  };
}

class MockAccountStore {
  records: RecordValue[];
  createCalls = 0;
  createThrowsAfterApply = false;
  createHook?: (created: RecordValue, store: MockAccountStore) => void;
  filterHook?: (
    filter: RecordValue,
    store: MockAccountStore,
  ) => void;
  updateHook?: (
    filter: RecordValue,
    update: RecordValue,
    store: MockAccountStore,
  ) => void;

  constructor(records: RecordValue[]) {
    this.records = structuredClone(records);
  }

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    this.filterHook?.(filter, this);
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
    this.createCalls += 1;
    const created = {
      ...structuredClone(value),
      id: `created-${this.createCalls}`,
      created_date: `2026-07-14T12:00:00.${
        String(this.createCalls).padStart(3, "0")
      }Z`,
    };
    this.records.push(created);
    this.createHook?.(created, this);
    if (this.createThrowsAfterApply) {
      throw new Error("simulated create response loss");
    }
    return structuredClone(created);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        updated += 1;
      }
    }
    this.updateHook?.(filter, update, this);
    return { updated };
  }
}

async function expectReservationError(
  action: () => Promise<unknown>,
  code: AppleAccountReservationError["code"],
) {
  let caught: unknown;
  try {
    await action();
  } catch (error) {
    caught = error;
  }
  assert(
    caught instanceof AppleAccountReservationError,
    `Expected reservation error, received ${String(caught)}`,
  );
  assert(
    (caught as AppleAccountReservationError).code === code,
    `Expected ${code}, received ${
      (caught as AppleAccountReservationError).code
    }`,
  );
}

Deno.test("Apple prepare returns the stable live token when deletion is absent", async () => {
  const store = new MockAccountStore([
    account("live", TOKEN_A, USER_ID),
  ]);
  const token = await reserveAppleAccountToken(
    store,
    USER_ID,
    () => NOW,
  );
  assert(token === TOKEN_A, "prepare did not return the canonical token");
  assert(store.createCalls === 0, "prepare created an unnecessary token");
});

Deno.test("Apple prepare observes the live future-leased deletion sentinel", async () => {
  const store = new MockAccountStore([
    account(
      "sentinel",
      TOKEN_A,
      USER_ID,
      "2026-07-14T12:05:00.000Z",
    ),
  ]);
  await expectReservationError(
    () => reserveAppleAccountToken(store, USER_ID, () => NOW),
    "active_lease",
  );
  assert(store.createCalls === 0, "active sentinel entered the create path");
});

Deno.test("new Apple reservation is created safely pending then claimed", async () => {
  const store = new MockAccountStore([]);
  const token = await reserveAppleAccountToken(
    store,
    USER_ID,
    () => NOW,
    () => TOKEN_A,
  );
  assert(token === TOKEN_A, "new pending token was not returned after claim");
  assert(store.createCalls === 1, "new reservation was not created once");
  assert(
    store.records.length === 1 &&
      store.records[0].user_id === USER_ID &&
      store.records[0].reservation_state === "active",
    "pending reservation did not CAS to the live owner",
  );
});

Deno.test("pre-check/create deletion race redacts the unhanded token", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const store = new MockAccountStore([]);
  store.createHook = (_created, target) => {
    target.records.push(
      account(
        "precommitted-sentinel",
        TOKEN_B,
        tombstone,
        "2026-07-14T12:05:00.000Z",
      ),
    );
  };

  await expectReservationError(
    () =>
      reserveAppleAccountToken(
        store,
        USER_ID,
        () => NOW,
        () => TOKEN_A,
      ),
    "deletion_in_progress",
  );
  assert(store.createCalls === 1, "test did not enter the create race");
  assert(
    store.records.every((record) => record.user_id !== USER_ID),
    "raw prepare-created binding survived deletion marker",
  );
});

Deno.test("lost create response cannot leave a raw binding outside deletion leases", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const store = new MockAccountStore([]);
  store.createThrowsAfterApply = true;
  store.createHook = (_pending, target) => {
    target.records.push(
      account(
        "precommitted-sentinel",
        TOKEN_B,
        tombstone,
        "2026-07-14T12:05:00.000Z",
      ),
    );
  };

  await expectReservationError(
    () =>
      reserveAppleAccountToken(
        store,
        USER_ID,
        () => NOW,
        () => TOKEN_A,
      ),
    "deletion_in_progress",
  );
  assert(store.createCalls === 1, "test did not apply the pending create");
  assert(
    store.records.every((record) => record.user_id !== USER_ID),
    "apply-then-throw create left a raw user binding",
  );
  const pending = store.records.find((record) =>
    record.app_account_token === TOKEN_A
  );
  assert(
    pending?.user_id === tombstone && pending?.reservation_state === "pending",
    "unknown create result was not durably fail-safe",
  );
});

Deno.test("lost pending claim and reconciliation outage leave raw identity behind a deletion-blocking lease", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const pending = {
    ...account("pending", TOKEN_A, tombstone),
    reservation_state: "pending",
  };
  const store = new MockAccountStore([pending]);
  let claimApplied = false;
  let reconciliationOutageUsed = false;
  store.updateHook = (_filter, update, target) => {
    if (claimApplied || update.$set?.user_id !== USER_ID) return;
    claimApplied = true;
    target.records.push({
      ...account(
        "deletion-marker",
        TOKEN_B,
        tombstone,
        "2026-07-14T12:05:00.000Z",
      ),
      reservation_state: "deletion_sentinel",
    });
    // updateMany has already mutated the pending row at this point.
    throw new Error("simulated claim response loss");
  };
  store.filterHook = (filter) => {
    if (
      claimApplied && !reconciliationOutageUsed && filter.id === "pending" &&
      filter.user_id === USER_ID && filter.last_used_at
    ) {
      reconciliationOutageUsed = true;
      throw new Error("simulated reconciliation read outage");
    }
  };

  await expectReservationError(
    () => reserveAppleAccountToken(store, USER_ID, () => NOW),
    "cas_contention",
  );

  const claimed = store.records.find((record) => record.id === "pending");
  assert(claimApplied, "test did not apply the pending claim");
  assert(reconciliationOutageUsed, "test did not lose the reconciliation read");
  assert(
    claimed?.user_id === USER_ID &&
      claimed?.reservation_state === "active" &&
      isAppleAccountLeaseActive(claimed?.last_used_at, NOW),
    "unknown raw claim was not protected by an atomic future lease",
  );

  let deletionError: unknown;
  try {
    await acquireAppleAccountDeletionLeases(
      store,
      USER_ID,
      tombstone,
      NOW,
      () => "33333333-3333-4333-8333-333333333333",
    );
  } catch (error) {
    deletionError = error;
  }
  assert(
    deletionError instanceof AppleAccountDeletionLeaseError &&
      deletionError.code === "active_lease",
    "deleteAccount crossed a raw reservation lease after unknown claim",
  );
});

Deno.test("post-CAS deletion marker prevents returning a newly stale token", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const store = new MockAccountStore([
    account("live", TOKEN_A, USER_ID),
  ]);
  let markerInserted = false;
  store.updateHook = (_filter, update, target) => {
    if (markerInserted || update.$set?.user_id) return;
    markerInserted = true;
    target.records.push(
      account(
        "precommitted-sentinel",
        TOKEN_B,
        tombstone,
        "2026-07-14T12:05:00.000Z",
      ),
    );
  };

  await expectReservationError(
    () => reserveAppleAccountToken(store, USER_ID, () => NOW),
    "deletion_in_progress",
  );
  assert(markerInserted, "test did not interleave after reservation CAS");
  assert(
    store.records.every((record) => record.user_id !== USER_ID),
    "post-CAS deletion race returned or retained the raw binding",
  );
});

Deno.test("expired own tombstone still blocks a new purchase prepare", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const store = new MockAccountStore([
    account("old-precommit", TOKEN_A, tombstone),
  ]);
  await expectReservationError(
    () => reserveAppleAccountToken(store, USER_ID, () => NOW),
    "deletion_in_progress",
  );
  assert(store.createCalls === 0, "tombstone marker entered the create path");
});
