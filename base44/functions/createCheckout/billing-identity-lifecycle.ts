const ENTITY_PAGE_SIZE = 100;
const LIFECYCLE_ATTEMPTS = 6;
const CLOCK_SKEW_MILLISECONDS = 5_000;

// Must exceed the maximum runtime of one backend invocation. Every caller also
// reasserts the exact token immediately at its persistence boundary.
export const BILLING_IDENTITY_LEASE_MILLISECONDS = 10 * 60 * 1_000;

type LifecycleRecord = {
  id?: string;
  subject_key?: string;
  state?: string;
  lease_until?: string;
  lease_token?: string;
  revision?: string;
  created_date?: string;
  updated_date?: string;
};

export type BillingIdentityLease = {
  recordID: string;
  subjectKey: string;
  state: "active" | "deleting";
  leaseToken: string;
  leaseUntil: string;
  revision: string;
};

export type BillingIdentityLifecycleErrorCode =
  | "incomplete_state"
  | "user_missing"
  | "deletion_in_progress"
  | "active_lease"
  | "duplicate_records"
  | "cas_contention"
  | "ambiguous";

export class BillingIdentityLifecycleError extends Error {
  public readonly retryable: boolean;

  constructor(
    public readonly code: BillingIdentityLifecycleErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "BillingIdentityLifecycleError";
    this.retryable = code === "active_lease" || code === "cas_contention";
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function billingIdentitySubjectKey(
  userIDValue: unknown,
): Promise<string> {
  const userID = clean(userIDValue);
  if (!userID) {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "A stable user id is required for lifecycle coordination.",
    );
  }
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-billing-lifecycle:${userID}`),
  );
  return `billing:${hex(digest).slice(0, 40)}`;
}

function lifecycleState(value: unknown): "active" | "deleting" {
  return clean(value) === "deleting" ? "deleting" : "active";
}

function exactRevisionFilter(record: LifecycleRecord) {
  const id = clean(record.id);
  const subjectKey = clean(record.subject_key);
  if (!id || !subjectKey) {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "The billing lifecycle row has no stable identity.",
    );
  }
  const revision = clean(record.revision);
  if (revision) return { id, subject_key: subjectKey, revision };
  const updatedDate = clean(record.updated_date);
  if (updatedDate) {
    return { id, subject_key: subjectKey, updated_date: updatedDate };
  }
  throw new BillingIdentityLifecycleError(
    "incomplete_state",
    "The billing lifecycle row has no CAS revision.",
  );
}

async function allMatchingRecords<T>(
  store: any,
  filter: Record<string, unknown>,
): Promise<T[]> {
  const records: T[] = [];
  for (let skip = 0;; skip += ENTITY_PAGE_SIZE) {
    const page: T[] = await store.filter(
      filter,
      "created_date",
      ENTITY_PAGE_SIZE,
      skip,
    ) || [];
    records.push(...page);
    if (page.length < ENTITY_PAGE_SIZE) return records;
  }
}

async function lifecycleRows(
  store: any,
  subjectKey: string,
): Promise<LifecycleRecord[]> {
  return await allMatchingRecords<LifecycleRecord>(store, {
    subject_key: subjectKey,
  });
}

function canonicalRecord(records: readonly LifecycleRecord[]): LifecycleRecord {
  return [...records].sort((left, right) =>
    clean(left.created_date).localeCompare(clean(right.created_date)) ||
    clean(left.id).localeCompare(clean(right.id))
  )[0];
}

export function isBillingIdentityLeaseActive(
  leaseUntilValue: unknown,
  now = new Date(),
): boolean {
  const leaseUntil = Date.parse(clean(leaseUntilValue));
  return Number.isFinite(leaseUntil) &&
    leaseUntil > now.getTime() + CLOCK_SKEW_MILLISECONDS;
}

async function deleteDuplicate(
  store: any,
  record: LifecycleRecord,
  subjectKey: string,
): Promise<void> {
  const id = clean(record.id);
  if (!id) {
    throw new BillingIdentityLifecycleError(
      "duplicate_records",
      "A duplicate billing lifecycle row has no id.",
    );
  }
  try {
    await store.delete(id);
  } catch {
    try {
      const remaining = await allMatchingRecords<LifecycleRecord>(store, {
        id,
        subject_key: subjectKey,
      });
      if (!remaining.length) return;
    } catch {
      // Unknown deletion is fail-closed and will be retried later.
    }
    throw new BillingIdentityLifecycleError(
      "ambiguous",
      "Duplicate billing lifecycle cleanup could not be reconciled.",
    );
  }
}

async function ensureSingletonLifecycleRecord(
  store: any,
  subjectKey: string,
  nowFactory: () => Date,
  randomUUID: () => string,
): Promise<LifecycleRecord> {
  for (let attempt = 0; attempt < LIFECYCLE_ATTEMPTS; attempt += 1) {
    const now = nowFactory();
    const records = await lifecycleRows(store, subjectKey);
    if (!records.length) {
      const revision = randomUUID();
      try {
        await store.create({
          subject_key: subjectKey,
          state: "active",
          lease_token: `initialized:${revision}`,
          lease_until: now.toISOString(),
          revision,
        });
      } catch {
        try {
          const created = await allMatchingRecords<LifecycleRecord>(store, {
            subject_key: subjectKey,
            revision,
          });
          if (created.length === 1) continue;
        } catch {
          // Creation may have applied. A later caller will converge it.
        }
        throw new BillingIdentityLifecycleError(
          "ambiguous",
          "Billing lifecycle initialization could not be reconciled.",
        );
      }
      continue;
    }
    if (records.length === 1) return records[0];

    // Only duplicate, inactive initialization rows can be converged
    // automatically. A deleting or live leased duplicate requires explicit
    // operator review; no raw writer or deletion may continue through it.
    if (
      records.some((record) =>
        lifecycleState(record.state) === "deleting" ||
        isBillingIdentityLeaseActive(record.lease_until, now)
      )
    ) {
      throw new BillingIdentityLifecycleError(
        "duplicate_records",
        "Conflicting billing lifecycle rows require service-role repair.",
      );
    }
    const canonical = canonicalRecord(records);
    for (const record of records) {
      if (clean(record.id) === clean(canonical.id)) continue;
      await deleteDuplicate(store, record, subjectKey);
    }
  }
  throw new BillingIdentityLifecycleError(
    "cas_contention",
    "Billing lifecycle initialization did not stabilize.",
  );
}

async function singletonRecord(
  store: any,
  subjectKey: string,
): Promise<LifecycleRecord | undefined> {
  const records = await lifecycleRows(store, subjectKey);
  if (records.length > 1) {
    throw new BillingIdentityLifecycleError(
      "duplicate_records",
      "Conflicting billing lifecycle rows block persistence.",
    );
  }
  return records[0];
}

function candidateLease(
  record: LifecycleRecord,
  subjectKey: string,
  state: "active" | "deleting",
  now: Date,
  randomUUID: () => string,
): BillingIdentityLease {
  const recordID = clean(record.id);
  if (!recordID) {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "The billing lifecycle row has no entity id.",
    );
  }
  return {
    recordID,
    subjectKey,
    state,
    leaseToken: `${state}:${randomUUID()}`,
    leaseUntil: new Date(
      now.getTime() + BILLING_IDENTITY_LEASE_MILLISECONDS,
    ).toISOString(),
    revision: randomUUID(),
  };
}

function leaseMatches(record: LifecycleRecord, lease: BillingIdentityLease) {
  return clean(record.id) === lease.recordID &&
    clean(record.subject_key) === lease.subjectKey &&
    lifecycleState(record.state) === lease.state &&
    clean(record.lease_token) === lease.leaseToken &&
    clean(record.lease_until) === lease.leaseUntil &&
    clean(record.revision) === lease.revision;
}

function recordNoLongerCarriesLease(
  record: LifecycleRecord,
  lease: BillingIdentityLease,
): boolean {
  return clean(record.id) === lease.recordID &&
    clean(record.subject_key) === lease.subjectKey &&
    (
      lifecycleState(record.state) !== lease.state ||
      clean(record.lease_token) !== lease.leaseToken ||
      clean(record.lease_until) !== lease.leaseUntil
    );
}

async function hasExactLease(
  store: any,
  lease: BillingIdentityLease,
): Promise<boolean> {
  const record = await singletonRecord(store, lease.subjectKey);
  return Boolean(record && leaseMatches(record, lease));
}

async function acquireLease(
  store: any,
  userIDValue: unknown,
  targetState: "active" | "deleting",
  nowFactory: () => Date,
  randomUUID: () => string,
  allowDeletingTakeover = true,
): Promise<BillingIdentityLease> {
  const subjectKey = await billingIdentitySubjectKey(userIDValue);
  for (let attempt = 0; attempt < LIFECYCLE_ATTEMPTS; attempt += 1) {
    const now = nowFactory();
    const current = await ensureSingletonLifecycleRecord(
      store,
      subjectKey,
      nowFactory,
      randomUUID,
    );
    const state = lifecycleState(current.state);
    if (
      state === "deleting" &&
      (targetState === "active" || !allowDeletingTakeover)
    ) {
      throw new BillingIdentityLifecycleError(
        "deletion_in_progress",
        "Account deletion is in progress or already completed.",
      );
    }
    if (isBillingIdentityLeaseActive(current.lease_until, now)) {
      throw new BillingIdentityLifecycleError(
        "active_lease",
        state === "deleting"
          ? "Another account deletion is in progress."
          : "Account identity is being updated.",
      );
    }

    const candidate = candidateLease(
      current,
      subjectKey,
      targetState,
      now,
      randomUUID,
    );
    let result: any;
    try {
      result = await store.updateMany(
        exactRevisionFilter(current),
        {
          $set: {
            state: candidate.state,
            lease_token: candidate.leaseToken,
            lease_until: candidate.leaseUntil,
            revision: candidate.revision,
          },
        },
      );
    } catch {
      try {
        if (await hasExactLease(store, candidate)) return candidate;
      } catch (error) {
        if (
          error instanceof BillingIdentityLifecycleError &&
          error.code === "duplicate_records"
        ) throw error;
      }
      throw new BillingIdentityLifecycleError(
        "ambiguous",
        "Billing lifecycle lease result could not be reconciled.",
      );
    }
    if (Number(result?.updated) === 1) {
      // A delayed concurrent initializer may have created a duplicate after
      // our CAS. Re-read the whole subject set before trusting the lease.
      if (await hasExactLease(store, candidate)) return candidate;
      throw new BillingIdentityLifecycleError(
        "duplicate_records",
        "Billing lifecycle became ambiguous during lease acquisition.",
      );
    }
  }
  throw new BillingIdentityLifecycleError(
    "cas_contention",
    "Billing lifecycle changed concurrently.",
  );
}

export async function acquireBillingWriterLease(
  store: any,
  userID: unknown,
  nowFactory: () => Date = () => new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<BillingIdentityLease> {
  return await acquireLease(store, userID, "active", nowFactory, randomUUID);
}

export async function acquireBillingDeletionMarker(
  store: any,
  userID: unknown,
  nowFactory: () => Date = () => new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<BillingIdentityLease> {
  return await acquireLease(store, userID, "deleting", nowFactory, randomUUID);
}

export async function acquireBillingIssuanceMarker(
  store: any,
  userID: unknown,
  nowFactory: () => Date = () => new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<BillingIdentityLease> {
  // Issuance may create an external bearer token. It transitions only from
  // active state and never takes over an expired deletion/quarantine row.
  return await acquireLease(
    store,
    userID,
    "deleting",
    nowFactory,
    randomUUID,
    false,
  );
}

async function assertExactActiveLease(
  store: any,
  lease: BillingIdentityLease,
  now: Date,
): Promise<void> {
  if (!isBillingIdentityLeaseActive(lease.leaseUntil, now)) {
    throw new BillingIdentityLifecycleError(
      "active_lease",
      "The billing lifecycle lease expired before persistence.",
    );
  }
  if (!(await hasExactLease(store, lease))) {
    throw new BillingIdentityLifecycleError(
      "cas_contention",
      "The billing lifecycle lease changed concurrently.",
    );
  }
}

export async function assertBillingWriterLease(
  store: any,
  lease: BillingIdentityLease,
  now = new Date(),
): Promise<void> {
  if (lease.state !== "active") {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "Writer lease required.",
    );
  }
  await assertExactActiveLease(store, lease, now);
}

export async function assertBillingDeletionMarker(
  store: any,
  lease: BillingIdentityLease,
  now = new Date(),
): Promise<void> {
  if (lease.state !== "deleting") {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "Deletion marker required.",
    );
  }
  await assertExactActiveLease(store, lease, now);
}

async function releaseLease(
  store: any,
  lease: BillingIdentityLease,
  now: Date,
  randomUUID: () => string,
): Promise<void> {
  const revision = randomUUID();
  const releasedAt = now.toISOString();
  let result: any;
  try {
    result = await store.updateMany(
      {
        id: lease.recordID,
        subject_key: lease.subjectKey,
        state: lease.state,
        lease_token: lease.leaseToken,
        lease_until: lease.leaseUntil,
        revision: lease.revision,
      },
      {
        $set: {
          state: "active",
          lease_token: `released:${revision}`,
          lease_until: releasedAt,
          revision,
        },
      },
    );
  } catch {
    try {
      const record = await singletonRecord(store, lease.subjectKey);
      if (
        record && clean(record.id) === lease.recordID &&
        lifecycleState(record.state) === "active" &&
        clean(record.lease_until) === releasedAt &&
        clean(record.revision) === revision
      ) return;
      // A response-lost release may already have been followed by another
      // valid writer/deletion lease. Never turn that completed cleanup into a
      // false failure or overwrite the replacement lease.
      if (record && recordNoLongerCarriesLease(record, lease)) return;
    } catch {
      // The bounded old lease or exact release remains fail-closed.
    }
    throw new BillingIdentityLifecycleError(
      "ambiguous",
      "Billing lifecycle lease release could not be reconciled.",
    );
  }
  if (Number(result?.updated) !== 1) {
    try {
      const record = await singletonRecord(store, lease.subjectKey);
      if (record && recordNoLongerCarriesLease(record, lease)) return;
    } catch {
      // Preserve the typed contention below when reconciliation is unreadable.
    }
    throw new BillingIdentityLifecycleError(
      "cas_contention",
      "Billing lifecycle lease changed before release.",
    );
  }
}

export async function releaseBillingWriterLease(
  store: any,
  lease: BillingIdentityLease,
  now = new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<void> {
  if (lease.state !== "active") {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "Writer lease required.",
    );
  }
  await releaseLease(store, lease, now, randomUUID);
}

export async function releaseBillingDeletionMarker(
  store: any,
  lease: BillingIdentityLease,
  now = new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<void> {
  if (lease.state !== "deleting") {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "Deletion marker required.",
    );
  }
  await releaseLease(store, lease, now, randomUUID);
}

export async function renewBillingDeletionMarker(
  store: any,
  lease: BillingIdentityLease,
  now = new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<void> {
  if (lease.state !== "deleting") {
    throw new BillingIdentityLifecycleError(
      "incomplete_state",
      "Deletion marker required.",
    );
  }
  const renewedUntil = new Date(Math.max(
    now.getTime() + BILLING_IDENTITY_LEASE_MILLISECONDS,
    (Date.parse(lease.leaseUntil) || 0) + 1_000,
  )).toISOString();
  const revision = randomUUID();
  const renewed = { ...lease, leaseUntil: renewedUntil, revision };
  let result: any;
  try {
    result = await store.updateMany(
      {
        id: lease.recordID,
        subject_key: lease.subjectKey,
        state: "deleting",
        lease_token: lease.leaseToken,
        lease_until: lease.leaseUntil,
        revision: lease.revision,
      },
      { $set: { lease_until: renewedUntil, revision } },
    );
  } catch {
    try {
      if (await hasExactLease(store, renewed)) {
        lease.leaseUntil = renewedUntil;
        lease.revision = revision;
        return;
      }
    } catch {
      // State remains deleting even if the exact renewal is unknown.
    }
    throw new BillingIdentityLifecycleError(
      "ambiguous",
      "Deletion marker renewal could not be reconciled.",
    );
  }
  if (Number(result?.updated) !== 1 || !(await hasExactLease(store, renewed))) {
    throw new BillingIdentityLifecycleError(
      "cas_contention",
      "Deletion marker changed before renewal.",
    );
  }
  lease.leaseUntil = renewedUntil;
  lease.revision = revision;
}
