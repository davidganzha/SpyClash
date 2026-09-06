import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  acquireBillingDeletionMarker,
  acquireBillingIssuanceMarker,
  acquireBillingWriterLease,
  assertBillingWriterLease,
  BILLING_IDENTITY_LEASE_MILLISECONDS,
  BillingIdentityLifecycleError,
  billingIdentitySubjectKey,
  isBillingIdentityLeaseActive,
  releaseBillingDeletionMarker,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

type Row = Record<string, unknown>;
type Update = { $set: Row };
const NOW = new Date("2026-09-06T16:00:00.000Z");
const ids = () => {
  let counter = 0;
  return () => `test-revision-${++counter}`;
};
const matches = (row: Row, filter: Row) =>
  Object.entries(filter).every(([key, value]) =>
    value && typeof value === "object" && "$exists" in value
      ? (row[key] !== undefined) === value.$exists
      : row[key] === value
  );
const token = (update: Update) => String(update.$set.lease_token || "");

class FaultStore {
  rows: Row[];
  readsToFail = 0;
  omitUpdateCountOnce = false;
  malformedUpdateCountOnce?: { updated: unknown };
  skipNextUpdateWithAcknowledgement?: Row;
  updates: { filter: Row; update: Update }[] = [];
  beforeUpdate?: (filter: Row, update: Update) => void;
  afterUpdate?: (filter: Row, update: Update, updated: number) => void;

  constructor(row: Row) {
    this.rows = [row];
  }

  async filter(filter: Row, _sort: string, limit: number, skip: number) {
    if (this.readsToFail > 0) {
      this.readsToFail -= 1;
      throw new Error("injected confirmation read failure");
    }
    return structuredClone(this.rows.filter((row) => matches(row, filter)))
      .slice(skip, skip + limit);
  }

  apply(filter: Row, update: Update) {
    let updated = 0;
    for (const row of this.rows) {
      if (!matches(row, filter)) continue;
      Object.assign(row, structuredClone(update.$set));
      updated += 1;
    }
    return updated;
  }

  async updateMany(filter: Row, update: Update) {
    this.updates.push(structuredClone({ filter, update }));
    this.beforeUpdate?.(filter, update);
    if (this.skipNextUpdateWithAcknowledgement) {
      const response = this.skipNextUpdateWithAcknowledgement;
      this.skipNextUpdateWithAcknowledgement = undefined;
      return response;
    }
    const updated = this.apply(filter, update);
    this.afterUpdate?.(filter, update, updated);
    if (this.omitUpdateCountOnce) {
      this.omitUpdateCountOnce = false;
      return {};
    }
    if (this.malformedUpdateCountOnce) {
      const response = this.malformedUpdateCountOnce;
      this.malformedUpdateCountOnce = undefined;
      return response;
    }
    return { updated };
  }
}

async function store(state = "active") {
  return new FaultStore({
    id: "lifecycle-row",
    subject_key: await billingIdentitySubjectKey("test-user"),
    state,
    lease_token: `${state}:previous`,
    lease_until: "2026-09-06T15:00:00.000Z",
    revision: "previous-revision",
    created_date: "2026-09-06T14:00:00.000Z",
  });
}

function failVerification(db: FaultStore, loseAcquisitionResponse = false) {
  db.afterUpdate = (_filter, update, updated) => {
    if (updated !== 1 || !/^(active|deleting):/.test(token(update))) return;
    db.afterUpdate = undefined;
    db.readsToFail = 1;
    if (loseAcquisitionResponse) throw new Error("injected acquisition response loss");
  };
}

async function assertReleasedAndReusable(db: FaultStore, randomUUID: () => string) {
  assertEquals(isBillingIdentityLeaseActive(db.rows[0].lease_until, NOW), false);
  const next = await acquireBillingDeletionMarker(db, "test-user", () => NOW, randomUUID);
  assertEquals(next.state, "deleting");
}

Deno.test("successful acquisition with failed verification releases its unpublished writer", async () => {
  const db = await store();
  const randomUUID = ids();
  failVerification(db);
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("missing update count reconciles the applied acquisition instead of orphaning it", async () => {
  const db = await store();
  db.omitUpdateCountOnce = true;
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  await assertBillingWriterLease(db, writer, NOW);
  await releaseBillingWriterLease(db, writer, NOW, randomUUID);
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("coercible malformed update counts never masquerade as definitive zero", async () => {
  for (const updated of [null, false, "", "0"]) {
    const db = await store();
    db.malformedUpdateCountOnce = { updated };
    const randomUUID = ids();
    const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
    await assertBillingWriterLease(db, writer, NOW);
    await releaseBillingWriterLease(db, writer, NOW, randomUUID);
    await assertReleasedAndReusable(db, randomUUID);
  }
});

Deno.test("response-lost acquisition plus unreadable verification releases before reporting ambiguity", async () => {
  const db = await store();
  const randomUUID = ids();
  failVerification(db, true);
  const error = await assertRejects(
    () => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "ambiguous");
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("aborted acquisition fences a response-lost CAS that has not committed yet", async () => {
  const db = await store();
  const randomUUID = ids();
  let late: (() => number) | undefined;
  db.beforeUpdate = (filter, update) => {
    if (!token(update).startsWith("active:")) return;
    db.beforeUpdate = undefined;
    late = () => db.apply(filter, update);
    db.readsToFail = 1;
    throw new Error("injected timeout before acquisition commit");
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  assertEquals(late?.(), 0, "late acquisition cannot revive the abandoned lease");
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("late acquisition between candidate cleanup and previous revision fence is still cleared", async () => {
  const db = await store();
  const randomUUID = ids();
  let late: (() => number) | undefined;
  let lateUpdated = -1;
  db.beforeUpdate = (filter, update) => {
    if (token(update).startsWith("active:")) {
      late = () => db.apply(filter, update);
      db.readsToFail = 1;
      throw new Error("injected timeout before acquisition commit");
    }
    if (token(update).startsWith("abandoned:") && !filter.lease_token && late) {
      lateUpdated = late();
      late = undefined;
    }
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  assertEquals(lateUpdated, 1);
  db.beforeUpdate = undefined;
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("legacy rows fence delayed acquisition even when updated_date does not change", async () => {
  const db = await store();
  delete db.rows[0].revision;
  db.rows[0].updated_date = NOW.toISOString();
  const randomUUID = ids();
  let late: (() => number) | undefined;
  db.beforeUpdate = (filter, update) => {
    if (!token(update).startsWith("active:")) return;
    db.beforeUpdate = undefined;
    assertEquals(filter.revision, { $exists: false });
    late = () => db.apply(filter, update);
    db.readsToFail = 1;
    throw new Error("injected timeout before legacy acquisition commit");
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  assertEquals(db.rows[0].updated_date, NOW.toISOString());
  assertEquals(late?.(), 0);
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("response-lost abort cleanup and its unreadable confirmation are reconciled", async () => {
  const db = await store();
  const randomUUID = ids();
  let acquisition = true;
  let cleanup = true;
  db.afterUpdate = (_filter, update, updated) => {
    if (updated !== 1) return;
    if (acquisition && token(update).startsWith("active:")) {
      acquisition = false;
      db.readsToFail = 1;
    } else if (cleanup && token(update).startsWith("abandoned:")) {
      cleanup = false;
      db.readsToFail = 1;
      throw new Error("injected cleanup response loss");
    }
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("malformed cleanup success count cannot report an unpublished lease as cleared", async () => {
  const db = await store();
  const randomUUID = ids();
  db.afterUpdate = (_filter, update, updated) => {
    if (updated !== 1 || !token(update).startsWith("active:")) return;
    db.afterUpdate = undefined;
    db.readsToFail = 1;
    db.skipNextUpdateWithAcknowledgement = { updated: true };
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID));
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("permanent abort cleanup outage retains protection and reports ambiguity within bounds", async () => {
  const db = await store();
  failVerification(db);
  db.beforeUpdate = (_filter, update) => {
    if (token(update).startsWith("abandoned:")) throw new Error("cleanup unavailable");
  };
  const error = await assertRejects(
    () => acquireBillingWriterLease(db, "test-user", () => NOW, ids()),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "ambiguous");
  assertEquals(db.updates.filter(({ update }) => token(update).startsWith("abandoned:")).length, 6);
  assertEquals(isBillingIdentityLeaseActive(db.rows[0].lease_until, NOW), true);
  const blocked = await assertRejects(
    () => acquireBillingDeletionMarker(db, "test-user", () => NOW, ids()),
    BillingIdentityLifecycleError,
  );
  assertEquals(blocked.code, "active_lease");
});

Deno.test("unpublished deletion retry cleanup preserves the preexisting deletion tombstone", async () => {
  const db = await store("deleting");
  failVerification(db);
  const randomUUID = ids();
  await assertRejects(() => acquireBillingDeletionMarker(db, "test-user", () => NOW, randomUUID));
  assertEquals(db.rows[0].state, "deleting");
  assertEquals(isBillingIdentityLeaseActive(db.rows[0].lease_until, NOW), false);
  const blocked = await assertRejects(
    () => acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID),
    BillingIdentityLifecycleError,
  );
  assertEquals(blocked.code, "deletion_in_progress");
  const retry = await acquireBillingDeletionMarker(db, "test-user", () => NOW, randomUUID);
  assertEquals(retry.state, "deleting");
});

Deno.test("unpublished issuance marker can restore active without issuing a credential", async () => {
  const db = await store();
  failVerification(db);
  const randomUUID = ids();
  await assertRejects(() => acquireBillingIssuanceMarker(db, "test-user", () => NOW, randomUUID));
  assertEquals(db.rows[0].state, "active");
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  await assertBillingWriterLease(db, writer, NOW);
});

Deno.test("unpublished lease cleanup cannot release a replacement deletion owner", async () => {
  const db = await store();
  failVerification(db);
  let replacement: Row | undefined;
  db.beforeUpdate = (_filter, update) => {
    if (!token(update).startsWith("abandoned:") || replacement) return;
    Object.assign(db.rows[0], {
      state: "deleting", lease_token: "deleting:replacement",
      lease_until: "2026-09-06T16:10:00.000Z", revision: "replacement-revision",
    });
    replacement = structuredClone(db.rows[0]);
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, ids()));
  assertEquals(db.rows[0], replacement);
});

Deno.test("abort cleanup never recreates a row removed after acquisition", async () => {
  const db = await store();
  failVerification(db);
  db.beforeUpdate = (_filter, update) => {
    if (token(update).startsWith("abandoned:")) db.rows = [];
  };
  await assertRejects(() => acquireBillingWriterLease(db, "test-user", () => NOW, ids()));
  assertEquals(db.rows.length, 0);
});

Deno.test("writer release retries transient pre-commit outages for callers without outer retry", async () => {
  const db = await store();
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  let failures = 2;
  db.beforeUpdate = (_filter, update) => {
    if (token(update).startsWith("released:") && failures-- > 0) throw new Error("release unavailable");
  };
  await releaseBillingWriterLease(db, writer, NOW, randomUUID);
  assertEquals(db.updates.filter(({ update }) => token(update).startsWith("released:")).length, 3);
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("malformed release success count requires reconciliation before reporting cleanup", async () => {
  const db = await store();
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  db.skipNextUpdateWithAcknowledgement = { updated: true };
  await releaseBillingWriterLease(db, writer, NOW, randomUUID);
  await assertReleasedAndReusable(db, randomUUID);
});

Deno.test("deletion release reconciles a lost response and one failed confirmation without reopening a successor", async () => {
  const db = await store();
  const randomUUID = ids();
  const deletion = await acquireBillingDeletionMarker(db, "test-user", () => NOW, randomUUID);
  let replacement: Row | undefined;
  db.afterUpdate = (_filter, update, updated) => {
    if (!token(update).startsWith("released:") || updated !== 1) return;
    Object.assign(db.rows[0], {
      state: "deleting", lease_token: "deleting:successor",
      lease_until: "2026-09-06T16:10:00.000Z", revision: "successor-revision",
    });
    replacement = structuredClone(db.rows[0]);
    db.readsToFail = 1;
    throw new Error("release response lost");
  };
  await releaseBillingDeletionMarker(db, deletion, NOW, randomUUID);
  assertEquals(db.rows[0], replacement);
});

Deno.test("release never recreates a lifecycle row removed by account deletion", async () => {
  const db = await store();
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  db.rows = [];
  await releaseBillingWriterLease(db, writer, NOW, randomUUID);
  assertEquals(db.rows.length, 0);
});

Deno.test("permanent release failure stays bounded and preserves the live lease", async () => {
  const db = await store();
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  db.beforeUpdate = (_filter, update) => {
    if (token(update).startsWith("released:")) throw new Error("release unavailable");
  };
  const error = await assertRejects(
    () => releaseBillingWriterLease(db, writer, NOW, randomUUID),
    BillingIdentityLifecycleError,
  );
  assertEquals(error.code, "ambiguous");
  assertEquals(db.updates.filter(({ update }) => token(update).startsWith("released:")).length, 3);
  await assertBillingWriterLease(db, writer, NOW);
});

Deno.test("a published lease is never stolen early even if its original process stops responding", async () => {
  const db = await store();
  const randomUUID = ids();
  const writer = await acquireBillingWriterLease(db, "test-user", () => NOW, randomUUID);
  assertEquals(Date.parse(writer.leaseUntil) - NOW.getTime(), BILLING_IDENTITY_LEASE_MILLISECONDS);
  const blocked = await assertRejects(
    () => acquireBillingDeletionMarker(db, "test-user", () => NOW, randomUUID),
    BillingIdentityLifecycleError,
  );
  assertEquals(blocked.code, "active_lease");
  const afterExpiry = new Date(NOW.getTime() + BILLING_IDENTITY_LEASE_MILLISECONDS + 1);
  await acquireBillingDeletionMarker(db, "test-user", () => afterExpiry, randomUUID);
  await assertRejects(() => assertBillingWriterLease(db, writer, afterExpiry));
});
