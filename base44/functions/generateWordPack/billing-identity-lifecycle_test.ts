import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  acquireBillingDeletionMarker,
  acquireBillingWriterLease,
  assertBillingWriterLease,
  BillingIdentityLifecycleError,
  billingIdentitySubjectKey,
  isBillingIdentityLeaseActive,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

type RecordValue = Record<string, any>;
const NOW = new Date("2026-07-14T12:00:00.000Z");

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
}

class MockLifecycleStore {
  records: RecordValue[];
  throwAfterApply = false;
  reconciliationOutage = false;
  exactLeaseApplied = false;
  nextID = 1;

  constructor(records: RecordValue[] = []) {
    this.records = structuredClone(records);
  }

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    if (
      this.reconciliationOutage && this.exactLeaseApplied &&
      filter.subject_key
    ) {
      this.reconciliationOutage = false;
      throw new Error("simulated lifecycle reconciliation outage");
    }
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `lifecycle-${this.nextID++}`,
      created_date: `2026-07-14T11:00:0${this.nextID}.000Z`,
      updated_date: NOW.toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        record.updated_date = NOW.toISOString();
        updated += 1;
      }
    }
    if (this.throwAfterApply && updated === 1) {
      this.throwAfterApply = false;
      this.exactLeaseApplied = true;
      throw new Error("simulated lifecycle response loss");
    }
    return { updated };
  }
}

async function inactiveRecord(userID: string, id: string) {
  const revision = `revision:${id}`;
  return {
    id,
    subject_key: await billingIdentitySubjectKey(userID),
    state: "active",
    lease_token: `initialized:${revision}`,
    lease_until: "2026-07-14T11:00:00.000Z",
    revision,
    created_date: `2026-07-14T11:00:0${id.endsWith("1") ? "1" : "2"}.000Z`,
    updated_date: "2026-07-14T11:00:00.000Z",
  };
}

Deno.test("writer lease blocks deletion and initializes protected lifecycle", async () => {
  const store = new MockLifecycleStore();
  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );
  assertEquals(store.records.length, 1);
  assertEquals(isBillingIdentityLeaseActive(writer.leaseUntil, NOW), true);

  const error = await assertRejects(
    () =>
      acquireBillingDeletionMarker(
        store,
        "user-1",
        () => NOW,
        sequence("delete"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "active_lease");
  assertEquals(error.retryable, true);

  await releaseBillingWriterLease(store, writer, NOW, sequence("release"));
  const deletion = await acquireBillingDeletionMarker(
    store,
    "user-1",
    () => NOW,
    sequence("delete"),
  );
  assertEquals(deletion.state, "deleting");
});

Deno.test("deleting state blocks writers and permits deletion retry after lease expiry", async () => {
  const store = new MockLifecycleStore();
  const deletion = await acquireBillingDeletionMarker(
    store,
    "user-1",
    () => NOW,
    sequence("delete"),
  );
  const afterExpiry = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const error = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => afterExpiry,
        sequence("writer"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "deletion_in_progress");

  const retry = await acquireBillingDeletionMarker(
    store,
    "user-1",
    () => afterExpiry,
    sequence("retry"),
  );
  assertEquals(retry.state, "deleting");
  assertEquals(retry.leaseToken === deletion.leaseToken, false);
});

Deno.test("lost writer response and unreadable reconciliation remain deletion-blocking", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
  ]);
  store.throwAfterApply = true;
  store.reconciliationOutage = true;

  const error = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => NOW,
        sequence("writer"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "ambiguous");
  assertEquals(
    isBillingIdentityLeaseActive(store.records[0].lease_until, NOW),
    true,
  );

  const deletionError = await assertRejects(
    () =>
      acquireBillingDeletionMarker(
        store,
        "user-1",
        () => NOW,
        sequence("delete"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(deletionError.code, "active_lease");
});

Deno.test("inactive duplicate initialization rows converge deterministically", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-2"),
    await inactiveRecord("user-1", "row-1"),
  ]);
  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );
  assertEquals(store.records.length, 1);
  assertEquals(store.records[0].id, "row-1");
  assertEquals(writer.recordID, "row-1");
});

Deno.test("live or deleting duplicate rows fail closed", async () => {
  const first = await inactiveRecord("user-1", "row-1");
  const second = {
    ...await inactiveRecord("user-1", "row-2"),
    state: "deleting",
  };
  const store = new MockLifecycleStore([first, second]);
  const error = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => NOW,
        sequence("writer"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "duplicate_records");
  assertEquals(store.records.length, 2);
});

Deno.test("client-writable User mirror cannot alter protected lifecycle", async () => {
  const clientUser = {
    id: "user-1",
    billing_identity_state: "deleting",
    billing_identity_lease_until: "2099-01-01T00:00:00.000Z",
  };
  const store = new MockLifecycleStore();
  clientUser.billing_identity_state = "active";
  const lease = await acquireBillingWriterLease(
    store,
    clientUser.id,
    () => NOW,
    sequence("writer"),
  );
  assertEquals(lease.state, "active");
  assertEquals("user_id" in store.records[0], false);
});

Deno.test("suspended writer cannot persist after lease expiry and deletion takeover", async () => {
  const store = new MockLifecycleStore();
  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );
  const resumedAt = new Date(NOW.getTime() + 11 * 60 * 1_000);
  const deletion = await acquireBillingDeletionMarker(
    store,
    "user-1",
    () => resumedAt,
    sequence("delete"),
  );
  assertEquals(deletion.state, "deleting");
  const error = await assertRejects(
    () => assertBillingWriterLease(store, writer, resumedAt),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "active_lease");
});
