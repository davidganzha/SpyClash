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
  injectInitializationAfterLeaseApply = false;
  promoteBeforeCleanupQuarantineID = "";
  extendBeforeCleanupQuarantineID = "";
  attemptStalePromotionAfterCleanupQuarantine = false;
  stalePromotionUpdated = -1;
  throwCleanupQuarantineAfterApply = false;
  throwCleanupDeleteAfterApply = false;
  blockCleanupDelete = false;
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
    const cleanup = this.records.find((record) =>
      record.id === id &&
      String(record.lease_token || "").startsWith("duplicate-cleanup:")
    );
    if (cleanup && this.blockCleanupDelete) {
      throw new Error("simulated cleanup delete outage");
    }
    this.records = this.records.filter((record) => record.id !== id);
    if (cleanup && this.throwCleanupDeleteAfterApply) {
      this.throwCleanupDeleteAfterApply = false;
      throw new Error("simulated lost cleanup delete response");
    }
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    const nextLeaseToken = String(update.$set?.lease_token || "");
    if (
      nextLeaseToken.startsWith("duplicate-cleanup:") &&
      this.promoteBeforeCleanupQuarantineID === String(filter.id || "")
    ) {
      this.promoteBeforeCleanupQuarantineID = "";
      const promoted = this.records.find((record) => record.id === filter.id);
      if (promoted) {
        Object.assign(promoted, {
          state: "active",
          lease_token: "active:concurrent-writer",
          lease_until: "2026-07-14T12:10:00.000Z",
          revision: "concurrent-writer-revision",
        });
      }
    }
    if (
      nextLeaseToken.startsWith("duplicate-cleanup:") &&
      this.extendBeforeCleanupQuarantineID === String(filter.id || "")
    ) {
      this.extendBeforeCleanupQuarantineID = "";
      const extended = this.records.find((record) => record.id === filter.id);
      if (extended) {
        extended.lease_until = "2026-07-14T12:10:00.000Z";
      }
    }
    let updated = 0;
    let updatedSubjectKey = "";
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        record.updated_date = NOW.toISOString();
        updatedSubjectKey = String(record.subject_key || "");
        updated += 1;
      }
    }
    if (
      nextLeaseToken.startsWith("duplicate-cleanup:") && updated === 1 &&
      this.attemptStalePromotionAfterCleanupQuarantine
    ) {
      this.attemptStalePromotionAfterCleanupQuarantine = false;
      let staleUpdated = 0;
      for (const record of this.records) {
        if (
          Object.entries(filter).every(([key, value]) => record[key] === value)
        ) {
          Object.assign(record, {
            state: "active",
            lease_token: "active:stale-writer",
            lease_until: "2026-07-14T12:10:00.000Z",
            revision: "stale-writer-revision",
          });
          staleUpdated += 1;
        }
      }
      this.stalePromotionUpdated = staleUpdated;
    }
    if (
      this.injectInitializationAfterLeaseApply && updated === 1 &&
      String(update.$set?.lease_token || "").startsWith("active:")
    ) {
      this.injectInitializationAfterLeaseApply = false;
      const revision = `injected-${this.nextID++}`;
      this.records.push({
        id: `lifecycle-${this.nextID++}`,
        subject_key: updatedSubjectKey,
        state: "active",
        lease_token: `initialized:${revision}`,
        lease_until: NOW.toISOString(),
        revision,
        created_date: NOW.toISOString(),
        updated_date: NOW.toISOString(),
      });
    }
    if (
      nextLeaseToken.startsWith("duplicate-cleanup:") && updated === 1 &&
      this.throwCleanupQuarantineAfterApply
    ) {
      this.throwCleanupQuarantineAfterApply = false;
      this.exactLeaseApplied = true;
      throw new Error("simulated lost cleanup quarantine response");
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

async function cleanupRecord(userID: string, id: string) {
  const revision = `cleanup:${id}`;
  return {
    id,
    subject_key: await billingIdentitySubjectKey(userID),
    state: "deleting",
    lease_token: `duplicate-cleanup:${revision}`,
    lease_until: "9999-12-31T23:59:59.999Z",
    revision,
    created_date: "2026-07-14T11:00:02.000Z",
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

  await releaseBillingWriterLease(store, writer, NOW, sequence("release"));
  const deletion = await acquireBillingDeletionMarker(
    store,
    "user-1",
    () => NOW,
    sequence("delete"),
  );
  assertEquals(deletion.state, "deleting");
});

Deno.test("writer lease serializes competing room mutations", async () => {
  const store = new MockLifecycleStore();
  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("first-writer"),
  );

  const error = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => NOW,
        sequence("second-writer"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "active_lease");

  await releaseBillingWriterLease(store, writer, NOW, sequence("release"));
});

Deno.test("lost release response is idempotent on bounded retry", async () => {
  const store = new MockLifecycleStore();
  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );

  store.throwAfterApply = true;
  store.reconciliationOutage = true;
  const firstError = await assertRejects(
    () => releaseBillingWriterLease(store, writer, NOW, sequence("release")),
    BillingIdentityLifecycleError,
  );
  assertEquals(firstError.code, "ambiguous");

  await releaseBillingWriterLease(store, writer, NOW, sequence("retry"));
  assertEquals(
    isBillingIdentityLeaseActive(store.records[0].lease_until, NOW),
    false,
  );
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

Deno.test("promotion before cleanup quarantine never deletes the live lease", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    await inactiveRecord("user-1", "row-2"),
  ]);
  store.promoteBeforeCleanupQuarantineID = "row-2";

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
  assertEquals(
    store.records.find((row) => row.id === "row-2")?.lease_token,
    "active:concurrent-writer",
  );
});

Deno.test("lease extension before cleanup quarantine loses the exact CAS", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    await inactiveRecord("user-1", "row-2"),
  ]);
  store.extendBeforeCleanupQuarantineID = "row-2";

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
  assertEquals(
    store.records.find((row) => row.id === "row-2")?.lease_until,
    "2026-07-14T12:10:00.000Z",
  );
});

Deno.test("malformed initialization lease is never quarantined", async () => {
  const malformed = {
    ...await inactiveRecord("user-1", "row-2"),
    lease_until: "not-a-date",
  };
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    malformed,
  ]);

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
  assertEquals(
    store.records.find((row) => row.id === "row-2")?.lease_token,
    malformed.lease_token,
  );
});

Deno.test("cleanup quarantine makes a stale initialization promotion lose CAS", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    await inactiveRecord("user-1", "row-2"),
  ]);
  store.attemptStalePromotionAfterCleanupQuarantine = true;

  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );

  assertEquals(store.stalePromotionUpdated, 0);
  assertEquals(store.records.length, 1);
  assertEquals(writer.recordID, "row-1");
});

Deno.test("lost quarantine and delete responses reconcile without duplicate loss", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    await inactiveRecord("user-1", "row-2"),
  ]);
  store.throwCleanupQuarantineAfterApply = true;
  store.throwCleanupDeleteAfterApply = true;

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

Deno.test("response-lost quarantine survives unreadable reconciliation and resumes", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
    await inactiveRecord("user-1", "row-2"),
  ]);
  store.throwCleanupQuarantineAfterApply = true;
  store.reconciliationOutage = true;

  const first = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => NOW,
        sequence("first"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(first.code, "ambiguous");
  assertEquals(
    store.records.some((row) =>
      row.lease_token.startsWith("duplicate-cleanup:") &&
      row.state === "deleting"
    ),
    true,
  );

  const recovered = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("recovered"),
  );
  assertEquals(recovered.recordID, "row-1");
  assertEquals(store.records.length, 1);
});

Deno.test("singleton cleanup quarantine blocks takeover and is recoverable", async () => {
  const store = new MockLifecycleStore([
    await cleanupRecord("user-1", "row-1"),
  ]);
  store.blockCleanupDelete = true;

  const writerError = await assertRejects(
    () =>
      acquireBillingWriterLease(
        store,
        "user-1",
        () => NOW,
        sequence("writer"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(writerError.code, "ambiguous");
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
  assertEquals(deletionError.code, "ambiguous");
  assertEquals(store.records[0].state, "deleting");
  assertEquals(
    store.records[0].lease_token.startsWith("duplicate-cleanup:"),
    true,
  );

  store.blockCleanupDelete = false;
  const recovered = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("recovered"),
  );
  assertEquals(recovered.state, "active");
  assertEquals(store.records.length, 1);
  assertEquals(
    store.records[0].lease_token.startsWith("duplicate-cleanup:"),
    false,
  );
});

Deno.test("late initialization duplicate preserves the exact writer lease", async () => {
  const store = new MockLifecycleStore([
    await inactiveRecord("user-1", "row-1"),
  ]);
  store.injectInitializationAfterLeaseApply = true;

  const writer = await acquireBillingWriterLease(
    store,
    "user-1",
    () => NOW,
    sequence("writer"),
  );

  assertEquals(store.records.length, 1);
  assertEquals(store.records[0].id, "row-1");
  assertEquals(store.records[0].lease_token, writer.leaseToken);
  await assertBillingWriterLease(store, writer, NOW);
});

Deno.test("single live writer wins over an older initialization duplicate", async () => {
  const inactive = await inactiveRecord("user-1", "row-1");
  const active = {
    ...await inactiveRecord("user-1", "row-2"),
    lease_token: "active:existing-writer",
    lease_until: "2026-07-14T12:10:00.000Z",
  };
  const store = new MockLifecycleStore([inactive, active]);

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

  assertEquals(error.code, "active_lease");
  assertEquals(store.records.length, 1);
  assertEquals(store.records[0].id, "row-2");
});

Deno.test("multiple live writer duplicates fail closed", async () => {
  const first = {
    ...await inactiveRecord("user-1", "row-1"),
    lease_token: "active:first-writer",
    lease_until: "2026-07-14T12:10:00.000Z",
  };
  const second = {
    ...await inactiveRecord("user-1", "row-2"),
    lease_token: "active:second-writer",
    lease_until: "2026-07-14T12:10:00.000Z",
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

Deno.test("deleting duplicate rows fail closed", async () => {
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
