import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  acquireBillingDeletionMarker,
  BillingIdentityLifecycleError,
  isBillingIdentityLeaseActive,
} from "./billing-identity-lifecycle.ts";
import {
  deletedAccountTombstone,
  persistStripeEntitlement,
  REDACTED_ENTITLEMENT_EMAIL,
  StripeEntitlementPersistenceError,
} from "./stripe-entitlement-persistence.ts";
import { reconcileStripeEntitlementState } from "./stripe-entitlement.ts";

type RecordValue = Record<string, any>;
const USER_ID = "user-1";
const SUBSCRIPTION_ID = "sub_legacy";
const NOW = new Date("2026-07-14T12:00:00.000Z");

function sequence(prefix: string) {
  let value = 0;
  return () => `${prefix}-${++value}`;
}

class MockUserStore {
  records: RecordValue[];
  nextID = 1;

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
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
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
    return { updated };
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `lifecycle-${this.nextID++}`,
      created_date: NOW.toISOString(),
      updated_date: NOW.toISOString(),
    };
    this.records.push(created);
    return structuredClone(created);
  }

  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }
}

class MockEntitlementStore {
  records: RecordValue[];
  updateCalls: Array<{ filter: RecordValue; update: RecordValue }> = [];
  createCalls: RecordValue[] = [];
  beforeUpdate?: (
    filter: RecordValue,
    update: RecordValue,
    store: MockEntitlementStore,
  ) => void;
  createThrowsAfterApply = false;
  updateThrowsAfterApply = false;
  reconciliationOutage = false;
  createApplied = false;
  updateApplied = false;

  constructor(records: RecordValue[]) {
    this.records = structuredClone(records);
  }

  async filter(
    filter: RecordValue,
    _sort: string,
    limit: number,
    skip: number,
  ) {
    if (
      this.reconciliationOutage && (this.createApplied || this.updateApplied) &&
      filter.write_revision
    ) {
      this.reconciliationOutage = false;
      throw new Error("simulated entitlement reconciliation outage");
    }
    return this.records
      .filter((record) =>
        Object.entries(filter).every(([key, value]) => record[key] === value)
      )
      .slice(skip, skip + limit)
      .map((record) => structuredClone(record));
  }

  async updateMany(filter: RecordValue, update: RecordValue) {
    this.updateCalls.push({
      filter: structuredClone(filter),
      update: structuredClone(update),
    });
    this.beforeUpdate?.(filter, update, this);
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, update.$set || {});
        updated += 1;
      }
    }
    if (this.updateThrowsAfterApply && updated === 1) {
      this.updateApplied = true;
      throw new Error("simulated update response loss");
    }
    return { updated };
  }

  async create(value: RecordValue) {
    const created = {
      ...structuredClone(value),
      id: `created-${this.createCalls.length + 1}`,
      created_date: "2026-07-14T12:00:00.000Z",
      updated_date: "2026-07-14T12:00:00.000Z",
    };
    this.records.push(created);
    this.createCalls.push(structuredClone(created));
    if (this.createThrowsAfterApply) {
      this.createApplied = true;
      throw new Error("simulated create response loss");
    }
    return structuredClone(created);
  }
}

function activeUser() {
  return {
    id: USER_ID,
    email: "operative@example.com",
    updated_date: "2026-07-14T11:00:00.000Z",
  };
}

function entitlement(userID = USER_ID): RecordValue {
  return {
    id: "ent-1",
    source_key: `stripe:${SUBSCRIPTION_ID}`,
    user_id: userID,
    user_email: userID === USER_ID
      ? "operative@example.com"
      : REDACTED_ENTITLEMENT_EMAIL,
    provider: "stripe",
    product_id: "legacy_subscription",
    stripe_subscription_id: SUBSCRIPTION_ID,
    status: "active",
    environment: "production",
    expires_at: "2026-08-14T12:00:00.000Z",
    last_verified_at: "2026-07-14T11:00:00.000Z",
    provider_event_at: "2026-07-14T11:00:00.000Z",
    provider_event_id: "evt-old",
    created_date: "2026-01-01T00:00:00.000Z",
    updated_date: "2026-07-14T11:00:00.000Z",
    write_revision: "revision-old",
  };
}

function ordinaryBuild(status: string) {
  return (current: RecordValue | undefined, ownerUserID: string) => ({
    record: {
      ...(current || entitlement(ownerUserID)),
      user_id: ownerUserID,
      user_email: current?.user_email || "operative@example.com",
      status,
      last_verified_at: NOW.toISOString(),
    },
    shouldPersist: true,
  });
}

Deno.test("stale webhook CAS cannot restore raw owner after deletion tombstones the row", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const userStore = new MockUserStore([activeUser()]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([entitlement()]);
  let interleaved = false;
  store.beforeUpdate = (filter, update, target) => {
    if (interleaved || !update.$set?.status || filter.user_id !== USER_ID) {
      return;
    }
    interleaved = true;
    Object.assign(target.records[0], {
      user_id: tombstone,
      user_email: REDACTED_ENTITLEMENT_EMAIL,
      write_revision: "deletion-revision",
    });
  };

  const result = await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: USER_ID,
    build: ordinaryBuild("canceled"),
    nowFactory: () => NOW,
    randomUUID: sequence("race"),
  });

  assert(interleaved, "test did not interleave deletion before stale CAS");
  assertEquals(result.ownerUserID, tombstone);
  assertEquals(store.records[0].user_id, tombstone);
  assertEquals(store.records[0].user_email, REDACTED_ENTITLEMENT_EMAIL);
  const providerWrites = store.updateCalls.filter((call) =>
    call.update.$set?.status
  );
  assert(
    providerWrites.every((call) =>
      !("user_id" in call.update.$set) && !("user_email" in call.update.$set)
    ),
    "provider update carried stale identity fields",
  );
});

Deno.test("checkSubscription-style persistence cannot create while deletion marker owns lifecycle", async () => {
  const userStore = new MockUserStore([activeUser()]);
  const lifecycleStore = new MockUserStore([]);
  await acquireBillingDeletionMarker(
    lifecycleStore,
    USER_ID,
    () => NOW,
    sequence("deleting"),
  );
  const store = new MockEntitlementStore([]);

  const error = await assertRejects(
    () =>
      persistStripeEntitlement({
        entitlementStore: store,
        lifecycleStore,
        userStore,
        subscriptionID: SUBSCRIPTION_ID,
        requestedUserID: USER_ID,
        build: ordinaryBuild("active"),
        nowFactory: () => NOW,
        randomUUID: sequence("blocked"),
      }),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "deletion_in_progress");
  assertEquals(store.createCalls.length, 0);
});

Deno.test("lost raw create response plus reconciliation outage retains deletion-blocking writer lease", async () => {
  const userStore = new MockUserStore([activeUser()]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([]);
  store.createThrowsAfterApply = true;
  store.reconciliationOutage = true;

  const error = await assertRejects(
    () =>
      persistStripeEntitlement({
        entitlementStore: store,
        lifecycleStore,
        userStore,
        subscriptionID: SUBSCRIPTION_ID,
        requestedUserID: USER_ID,
        build: ordinaryBuild("active"),
        nowFactory: () => NOW,
        randomUUID: sequence("ambiguous"),
      }),
    StripeEntitlementPersistenceError,
  );
  assertEquals(error.code, "ambiguous");
  assertEquals(store.records[0].user_id, USER_ID);
  assertEquals(
    isBillingIdentityLeaseActive(
      lifecycleStore.records[0].lease_until,
      NOW,
    ),
    true,
  );
  const deletionError = await assertRejects(
    () =>
      acquireBillingDeletionMarker(
        lifecycleStore,
        USER_ID,
        () => NOW,
        sequence("delete"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(deletionError.code, "active_lease");
});

Deno.test("lost raw update response plus reconciliation outage retains deletion-blocking writer lease", async () => {
  const userStore = new MockUserStore([activeUser()]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([entitlement()]);
  store.updateThrowsAfterApply = true;
  store.reconciliationOutage = true;

  const error = await assertRejects(
    () =>
      persistStripeEntitlement({
        entitlementStore: store,
        lifecycleStore,
        userStore,
        subscriptionID: SUBSCRIPTION_ID,
        requestedUserID: USER_ID,
        build: ordinaryBuild("canceled"),
        nowFactory: () => NOW,
        randomUUID: sequence("ambiguous-update"),
      }),
    StripeEntitlementPersistenceError,
  );
  assertEquals(error.code, "ambiguous");
  assertEquals(store.records[0].user_id, USER_ID);
  assertEquals(store.records[0].status, "canceled");
  assert(
    store.updateCalls.every((call) =>
      !("user_id" in call.update.$set) && !("user_email" in call.update.$set)
    ),
  );
  assertEquals(
    isBillingIdentityLeaseActive(
      lifecycleStore.records[0].lease_until,
      NOW,
    ),
    true,
  );
  const deletionError = await assertRejects(
    () =>
      acquireBillingDeletionMarker(
        lifecycleStore,
        USER_ID,
        () => NOW,
        sequence("delete-after-update"),
      ),
    BillingIdentityLifecycleError,
  );
  assertEquals(deletionError.code, "active_lease");
});

Deno.test("late Stripe metadata for a deleted User creates only tombstoned identity", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const userStore = new MockUserStore([]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([]);

  const result = await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: USER_ID,
    allowMissingUserTombstone: true,
    build: ordinaryBuild("active"),
    nowFactory: () => NOW,
    randomUUID: sequence("late"),
  });

  assertEquals(result.ownerUserID, tombstone);
  assertEquals(store.createCalls.length, 1);
  assertEquals(store.records[0].user_id, tombstone);
  assertEquals(store.records[0].user_email, REDACTED_ENTITLEMENT_EMAIL);
});

Deno.test("missing User one-way redacts an orphaned raw Stripe row", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const userStore = new MockUserStore([]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([entitlement()]);

  const result = await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: USER_ID,
    allowMissingUserTombstone: true,
    build: ordinaryBuild("expired"),
    nowFactory: () => NOW,
    randomUUID: sequence("orphan"),
  });

  assertEquals(result.ownerUserID, tombstone);
  assertEquals(store.records[0].user_id, tombstone);
  assertEquals(store.records[0].user_email, REDACTED_ENTITLEMENT_EMAIL);
  assert(
    store.updateCalls.slice(1).every((call) =>
      !("user_id" in call.update.$set) && !("user_email" in call.update.$set)
    ),
  );
});

Deno.test("missing User converges a raw plus tombstone pair to tombstones", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const raw = entitlement();
  const retained = {
    ...entitlement(tombstone),
    id: "ent-retained",
    write_revision: "revision-retained",
  };
  const userStore = new MockUserStore([]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([raw, retained]);

  await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: USER_ID,
    allowMissingUserTombstone: true,
    build: ordinaryBuild("expired"),
    nowFactory: () => NOW,
    randomUUID: sequence("mixed-orphan"),
  });

  assertEquals(
    store.records.map((record) => record.user_id),
    [tombstone, tombstone],
  );
  assertEquals(
    store.records.map((record) => record.user_email),
    [REDACTED_ENTITLEMENT_EMAIL, REDACTED_ENTITLEMENT_EMAIL],
  );
});

Deno.test("tombstone provider update is identity-free", async () => {
  const tombstone = await deletedAccountTombstone(USER_ID);
  const userStore = new MockUserStore([]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([entitlement(tombstone)]);

  await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: tombstone,
    allowMissingUserTombstone: true,
    build: ordinaryBuild("expired"),
    nowFactory: () => NOW,
    randomUUID: sequence("tombstone"),
  });

  assertEquals(store.records[0].user_id, tombstone);
  assertEquals(store.records[0].user_email, REDACTED_ENTITLEMENT_EMAIL);
  assert(
    store.updateCalls.every((call) =>
      !("user_id" in call.update.$set) && !("user_email" in call.update.$set)
    ),
  );
});

Deno.test("concurrent newer Stripe event wins durable CAS retry", async () => {
  const userStore = new MockUserStore([activeUser()]);
  const lifecycleStore = new MockUserStore([]);
  const store = new MockEntitlementStore([entitlement()]);
  let interleaved = false;
  store.beforeUpdate = (filter, update, target) => {
    if (interleaved || !update.$set?.provider_event_id) return;
    interleaved = true;
    Object.assign(target.records[0], {
      provider_event_at: "2026-07-14T12:03:00.000Z",
      provider_event_id: "evt-newer",
      status: "active",
      write_revision: "concurrent-newer",
    });
  };

  const incoming = {
    ...entitlement(),
    provider_event_at: "2026-07-14T12:02:00.000Z",
    provider_event_id: "evt-delayed",
    status: "canceled",
  };
  const result = await persistStripeEntitlement({
    entitlementStore: store,
    lifecycleStore,
    userStore,
    subscriptionID: SUBSCRIPTION_ID,
    requestedUserID: USER_ID,
    build: (current) => reconcileStripeEntitlementState({ current, incoming }),
    nowFactory: () => NOW,
    randomUUID: sequence("cursor"),
  });

  assert(interleaved);
  assertEquals(result.persisted, false);
  assertEquals(store.records[0].provider_event_id, "evt-newer");
  assertEquals(store.records[0].status, "active");
});
