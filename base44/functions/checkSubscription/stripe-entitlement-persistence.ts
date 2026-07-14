import {
  acquireBillingWriterLease,
  assertBillingWriterLease,
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
  releaseBillingWriterLease,
} from "./billing-identity-lifecycle.ts";

export const REDACTED_ENTITLEMENT_EMAIL = "deleted-account@redacted.invalid";

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function deletedAccountTombstone(value: unknown): Promise<string> {
  const userID = String(value ?? "").trim();
  if (!userID) throw new Error("A stable user id is required.");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`spyclash-deleted-account:${userID}`),
  );
  return `deleted:${hex(digest).slice(0, 40)}`;
}

export type EntitlementRecord = {
  id?: string;
  source_key?: string;
  user_id?: string;
  user_email?: string;
  provider?: string;
  product_id?: string;
  price_id?: string;
  stripe_subscription_id?: string;
  stripe_refund_blocked_charge_ids?: string[];
  stripe_dispute_blocked_charge_ids?: string[];
  stripe_refund_event_cursors?: Record<string, string>;
  stripe_dispute_event_cursors?: Record<string, string>;
  provider_customer_id?: string;
  status?: string;
  purchased_at?: string;
  expires_at?: string;
  environment?: string;
  cancel_at_period_end?: boolean;
  last_verified_at?: string;
  provider_event_at?: string;
  provider_event_id?: string;
};

const ENTITY_PAGE_SIZE = 100;
const PERSISTENCE_ATTEMPTS = 4;
const DELETED_ACCOUNT_PATTERN = /^deleted:[0-9a-f]{40}$/;

export type StripePersistenceRecord = EntitlementRecord & {
  id?: string;
  created_date?: string;
  updated_date?: string;
  write_revision?: string;
};

export type StripeEntitlementBuildResult = {
  record: EntitlementRecord;
  shouldPersist: boolean;
};

export type StripeEntitlementPersistenceResult = {
  record: StripePersistenceRecord;
  persisted: boolean;
  ownerUserID: string;
  deletedAccount: boolean;
};

export type StripeEntitlementPersistenceErrorCode =
  | "incomplete_binding"
  | "owner_conflict"
  | "cas_contention"
  | "ambiguous";

export class StripeEntitlementPersistenceError extends Error {
  constructor(
    public readonly code: StripeEntitlementPersistenceErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "StripeEntitlementPersistenceError";
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function isDeletedOwner(value: unknown): boolean {
  return DELETED_ACCOUNT_PATTERN.test(clean(value));
}

function canonicalRecord(
  records: readonly StripePersistenceRecord[],
): StripePersistenceRecord | undefined {
  return [...records].sort((left, right) =>
    clean(left.created_date).localeCompare(clean(right.created_date)) ||
    clean(left.id).localeCompare(clean(right.id))
  )[0];
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

async function matchingStripeRecords(
  store: any,
  subscriptionID: string,
): Promise<StripePersistenceRecord[]> {
  return await allMatchingRecords<StripePersistenceRecord>(store, {
    provider: "stripe",
    stripe_subscription_id: subscriptionID,
  });
}

function exactRecordCASFilter(record: StripePersistenceRecord) {
  const id = clean(record.id);
  const ownerUserID = clean(record.user_id);
  if (!id || !ownerUserID) {
    throw new StripeEntitlementPersistenceError(
      "incomplete_binding",
      "The Stripe entitlement binding is incomplete.",
    );
  }
  const revision = clean(record.write_revision);
  if (revision) return { id, user_id: ownerUserID, write_revision: revision };
  const updatedDate = clean(record.updated_date);
  if (updatedDate) {
    return { id, user_id: ownerUserID, updated_date: updatedDate };
  }
  throw new StripeEntitlementPersistenceError(
    "incomplete_binding",
    "The Stripe entitlement has no CAS revision.",
  );
}

function providerPatch(record: EntitlementRecord, revision: string) {
  const immutable = new Set([
    "id",
    "user_id",
    "user_email",
    "source_key",
    "provider",
    "stripe_subscription_id",
    "created_date",
    "updated_date",
    "write_revision",
  ]);
  return {
    ...Object.fromEntries(
      Object.entries(record).filter(([key, value]) =>
        !immutable.has(key) && value !== undefined
      ),
    ),
    write_revision: revision,
  };
}

function createPayload(
  record: EntitlementRecord,
  ownerUserID: string,
  revision: string,
) {
  return {
    ...Object.fromEntries(
      Object.entries(record).filter(([key, value]) =>
        ![
          "id",
          "created_date",
          "updated_date",
          "write_revision",
        ].includes(key) && value !== undefined
      ),
    ),
    user_id: ownerUserID,
    user_email: isDeletedOwner(ownerUserID)
      ? REDACTED_ENTITLEMENT_EMAIL
      : record.user_email,
    provider: "stripe",
    write_revision: revision,
  };
}

async function exactAppliedRevision(
  store: any,
  recordID: string,
  ownerUserID: string,
  revision: string,
): Promise<StripePersistenceRecord | undefined> {
  const records = await allMatchingRecords<StripePersistenceRecord>(store, {
    id: recordID,
    user_id: ownerUserID,
    write_revision: revision,
  });
  return records.length === 1 ? records[0] : undefined;
}

async function redactOrphanedRawRecord(input: {
  store: any;
  record: StripePersistenceRecord;
  tombstoneUserID: string;
  randomUUID: () => string;
}): Promise<boolean> {
  const revision = input.randomUUID();
  let result: any;
  try {
    result = await input.store.updateMany(
      exactRecordCASFilter(input.record),
      {
        $set: {
          user_id: input.tombstoneUserID,
          user_email: REDACTED_ENTITLEMENT_EMAIL,
          write_revision: revision,
        },
      },
    );
  } catch {
    try {
      if (
        await exactAppliedRevision(
          input.store,
          clean(input.record.id),
          input.tombstoneUserID,
          revision,
        )
      ) return true;
    } catch {
      // The one-way redaction may have applied. Never issue a raw fallback.
    }
    throw new StripeEntitlementPersistenceError(
      "ambiguous",
      "The orphaned Stripe entitlement redaction could not be reconciled.",
    );
  }
  return Number(result?.updated) === 1;
}

/**
 * Serializes raw Stripe ownership through the User lifecycle row and persists
 * provider state through owner+revision CAS. Existing provider updates never
 * carry identity fields, so a stale writer cannot restore deletion-redacted
 * identity even if a future caller weakens its retry policy.
 */
export async function persistStripeEntitlement(input: {
  entitlementStore: any;
  lifecycleStore: any;
  userStore: any;
  subscriptionID: unknown;
  requestedUserID: unknown;
  allowMissingUserTombstone?: boolean;
  build: (
    current: StripePersistenceRecord | undefined,
    ownerUserID: string,
  ) => StripeEntitlementBuildResult;
  nowFactory?: () => Date;
  randomUUID?: () => string;
}): Promise<StripeEntitlementPersistenceResult> {
  const subscriptionID = clean(input.subscriptionID);
  const initialRequestedUserID = clean(input.requestedUserID);
  if (!subscriptionID || !initialRequestedUserID) {
    throw new StripeEntitlementPersistenceError(
      "incomplete_binding",
      "Stripe subscription ownership is incomplete.",
    );
  }
  const nowFactory = input.nowFactory || (() => new Date());
  const randomUUID = input.randomUUID || (() => crypto.randomUUID());
  const rawRequestedUserID = isDeletedOwner(initialRequestedUserID)
    ? ""
    : initialRequestedUserID;
  const expectedTombstone = rawRequestedUserID
    ? await deletedAccountTombstone(rawRequestedUserID)
    : initialRequestedUserID;
  let effectiveRequestedUserID = initialRequestedUserID;
  let writerLease: BillingIdentityLease | undefined;
  let releaseWriterLease = true;

  try {
    for (let attempt = 0; attempt < PERSISTENCE_ATTEMPTS; attempt += 1) {
      const records = await matchingStripeRecords(
        input.entitlementStore,
        subscriptionID,
      );
      const owners = [
        ...new Set(records.map((record) => clean(record.user_id))),
      ];
      const deletionTransitionOwners = Boolean(rawRequestedUserID) &&
        owners.length > 1 &&
        owners.every((owner) =>
          owner === rawRequestedUserID || owner === expectedTombstone
        );
      if (
        owners.some((owner) => !owner) ||
        (owners.length > 1 && !deletionTransitionOwners) ||
        (deletionTransitionOwners && writerLease)
      ) {
        throw new StripeEntitlementPersistenceError(
          "owner_conflict",
          "Stripe subscription records have conflicting owners.",
        );
      }
      const observedOwner = owners.length === 1 ? owners[0] : "";

      if (
        observedOwner && observedOwner !== effectiveRequestedUserID &&
        !(observedOwner === rawRequestedUserID &&
          effectiveRequestedUserID === expectedTombstone) &&
        !(observedOwner === expectedTombstone && rawRequestedUserID)
      ) {
        throw new StripeEntitlementPersistenceError(
          "owner_conflict",
          "Stripe subscription is bound to another SpyClash account.",
        );
      }
      if (observedOwner === expectedTombstone) {
        effectiveRequestedUserID = expectedTombstone;
      }

      if (!isDeletedOwner(effectiveRequestedUserID) && !writerLease) {
        let userExists: boolean;
        try {
          const users = await allMatchingRecords<Record<string, unknown>>(
            input.userStore,
            { id: effectiveRequestedUserID },
          );
          if (users.length > 1) {
            throw new StripeEntitlementPersistenceError(
              "owner_conflict",
              "The Stripe billing owner is ambiguous.",
            );
          }
          userExists = users.length === 1;
        } catch (error) {
          if (error instanceof StripeEntitlementPersistenceError) throw error;
          throw new BillingIdentityLifecycleError(
            "ambiguous",
            "The billing owner could not be verified.",
          );
        }
        if (!userExists) {
          if (input.allowMissingUserTombstone && rawRequestedUserID) {
            effectiveRequestedUserID = expectedTombstone;
            continue;
          }
          throw new BillingIdentityLifecycleError(
            "user_missing",
            "The billing owner no longer exists.",
          );
        }
        writerLease = await acquireBillingWriterLease(
          input.lifecycleStore,
          effectiveRequestedUserID,
          nowFactory,
          randomUUID,
        );
        // The lifecycle acquisition may have raced redaction. Always rebuild
        // from a fresh provider-source read while holding the writer lease.
        continue;
      }

      if (writerLease) {
        await assertBillingWriterLease(
          input.lifecycleStore,
          writerLease,
          nowFactory(),
        );
      }

      const rawOrphan = records.find((record) =>
        clean(record.user_id) === rawRequestedUserID
      );
      if (
        rawOrphan && isDeletedOwner(effectiveRequestedUserID) &&
        effectiveRequestedUserID === expectedTombstone
      ) {
        if (
          await redactOrphanedRawRecord({
            store: input.entitlementStore,
            record: rawOrphan,
            tombstoneUserID: expectedTombstone,
            randomUUID,
          })
        ) continue;
        continue;
      }

      const current = canonicalRecord(
        records.filter((record) =>
          clean(record.user_id) === effectiveRequestedUserID
        ),
      );
      const built = input.build(current, effectiveRequestedUserID);
      const record: StripePersistenceRecord = {
        ...built.record,
        user_id: effectiveRequestedUserID,
        user_email: isDeletedOwner(effectiveRequestedUserID)
          ? REDACTED_ENTITLEMENT_EMAIL
          : built.record.user_email,
      };
      if (!built.shouldPersist) {
        return {
          record: current || record,
          persisted: false,
          ownerUserID: effectiveRequestedUserID,
          deletedAccount: isDeletedOwner(effectiveRequestedUserID),
        };
      }

      if (writerLease) {
        await assertBillingWriterLease(
          input.lifecycleStore,
          writerLease,
          nowFactory(),
        );
      }
      const revision = randomUUID();
      if (current?.id) {
        let result: any;
        try {
          result = await input.entitlementStore.updateMany(
            exactRecordCASFilter(current),
            { $set: providerPatch(record, revision) },
          );
        } catch {
          try {
            const applied = await exactAppliedRevision(
              input.entitlementStore,
              clean(current.id),
              effectiveRequestedUserID,
              revision,
            );
            if (applied) {
              return {
                record: applied,
                persisted: true,
                ownerUserID: effectiveRequestedUserID,
                deletedAccount: isDeletedOwner(effectiveRequestedUserID),
              };
            }
          } catch {
            // Unknown persistence must retain the writer lease until expiry.
          }
          releaseWriterLease = false;
          throw new StripeEntitlementPersistenceError(
            "ambiguous",
            "The Stripe entitlement update could not be reconciled.",
          );
        }
        if (Number(result?.updated) !== 1) continue;
        return {
          record: { ...current, ...providerPatch(record, revision) },
          persisted: true,
          ownerUserID: effectiveRequestedUserID,
          deletedAccount: isDeletedOwner(effectiveRequestedUserID),
        };
      }

      let created: StripePersistenceRecord;
      try {
        created = await input.entitlementStore.create(
          createPayload(record, effectiveRequestedUserID, revision),
        );
      } catch {
        try {
          const reconciled = await allMatchingRecords<StripePersistenceRecord>(
            input.entitlementStore,
            {
              provider: "stripe",
              stripe_subscription_id: subscriptionID,
              user_id: effectiveRequestedUserID,
              write_revision: revision,
            },
          );
          if (reconciled.length === 1) {
            return {
              record: reconciled[0],
              persisted: true,
              ownerUserID: effectiveRequestedUserID,
              deletedAccount: isDeletedOwner(effectiveRequestedUserID),
            };
          }
        } catch {
          // Unknown create must retain the raw writer lease until expiry.
        }
        releaseWriterLease = false;
        throw new StripeEntitlementPersistenceError(
          "ambiguous",
          "The Stripe entitlement create could not be reconciled.",
        );
      }
      if (!clean(created?.id)) {
        throw new StripeEntitlementPersistenceError(
          "incomplete_binding",
          "The created Stripe entitlement has no entity id.",
        );
      }
      return {
        record: created,
        persisted: true,
        ownerUserID: effectiveRequestedUserID,
        deletedAccount: isDeletedOwner(effectiveRequestedUserID),
      };
    }

    throw new StripeEntitlementPersistenceError(
      "cas_contention",
      "Stripe entitlement state kept changing concurrently.",
    );
  } catch (error) {
    if (
      error instanceof StripeEntitlementPersistenceError &&
      error.code === "ambiguous"
    ) {
      releaseWriterLease = false;
    }
    throw error;
  } finally {
    if (writerLease && releaseWriterLease) {
      await releaseBillingWriterLease(
        input.lifecycleStore,
        writerLease,
        nowFactory(),
        randomUUID,
      );
    }
  }
}
