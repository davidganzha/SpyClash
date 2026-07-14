import {
  canonicalAppleAccountRecord,
  isAppleAccountLeaseActive,
} from "./apple-account-binding.ts";
import { deletedAccountTombstone } from "./deleted-account-identity.ts";

const ENTITY_PAGE_SIZE = 100;
const RESERVATION_ATTEMPTS = 4;
const RESERVATION_LEASE_MILLISECONDS = 5 * 60 * 1_000;
const PENDING_RESERVATION_STATE = "pending";
const ACTIVE_RESERVATION_STATE = "active";

type AppStoreAccountRecord = {
  id?: string;
  user_id?: string;
  app_account_token?: string;
  created_at?: string;
  created_date?: string;
  last_used_at?: string;
  reservation_state?: string;
};

export type AppleAccountReservationErrorCode =
  | "deletion_in_progress"
  | "active_lease"
  | "incomplete_binding"
  | "cas_contention";

export class AppleAccountReservationError extends Error {
  readonly code: AppleAccountReservationErrorCode;
  readonly status: number;

  constructor(
    code: AppleAccountReservationErrorCode,
    message: string,
    status = 503,
  ) {
    super(message);
    this.name = "AppleAccountReservationError";
    this.code = code;
    this.status = status;
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function canonicalUUID(value: unknown): string {
  const token = clean(value).toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(token)
  ) {
    throw new AppleAccountReservationError(
      "incomplete_binding",
      "Apple account binding is incomplete.",
    );
  }
  return token;
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

function reservationLeaseUntil(now: Date, observedLastUsedAt: string): string {
  return new Date(Math.max(
    now.getTime() + RESERVATION_LEASE_MILLISECONDS,
    (Date.parse(observedLastUsedAt) || 0) + 1,
  )).toISOString();
}

async function hasExactReservationLease(input: {
  store: any;
  recordID: string;
  userID: string;
  leaseUntil: string;
}): Promise<boolean> {
  const records = await allMatchingRecords<AppStoreAccountRecord>(
    input.store,
    {
      id: input.recordID,
      user_id: input.userID,
      last_used_at: input.leaseUntil,
    },
  );
  return records.length === 1 &&
    clean(records[0].reservation_state) === ACTIVE_RESERVATION_STATE;
}

async function releaseReservationLease(input: {
  store: any;
  recordID: string;
  userID: string;
  leaseUntil: string;
  releasedAt: string;
}): Promise<void> {
  let result: any;
  try {
    result = await input.store.updateMany(
      {
        id: input.recordID,
        user_id: input.userID,
        last_used_at: input.leaseUntil,
      },
      {
        $set: {
          reservation_state: ACTIVE_RESERVATION_STATE,
          last_used_at: input.releasedAt,
        },
      },
    );
  } catch {
    try {
      const released = await allMatchingRecords<AppStoreAccountRecord>(
        input.store,
        {
          id: input.recordID,
          user_id: input.userID,
          last_used_at: input.releasedAt,
        },
      );
      if (
        released.length === 1 &&
        clean(released[0].reservation_state) === ACTIVE_RESERVATION_STATE
      ) return;
    } catch {
      // Either outcome is privacy-safe: the raw row is still protected by the
      // future lease, or the lease was released and deleteAccount can own it.
    }
    throw new AppleAccountReservationError(
      "cas_contention",
      "Apple account reservation lease release could not be reconciled.",
    );
  }
  if (Number(result?.updated) !== 1) {
    throw new AppleAccountReservationError(
      "cas_contention",
      "Apple account reservation lease changed concurrently.",
    );
  }
}

async function isSafelyRedactedOrDeletionLeased(input: {
  store: any;
  recordID: string;
  userID: string;
  tombstoneUserID: string;
  now: Date;
}): Promise<boolean> {
  const records = await allMatchingRecords<AppStoreAccountRecord>(
    input.store,
    { id: input.recordID },
  );
  if (records.length !== 1) return false;
  const owner = clean(records[0].user_id);
  if (owner === input.tombstoneUserID) return true;
  return owner === input.userID &&
    isAppleAccountLeaseActive(records[0].last_used_at, input.now);
}

async function redactUnhandedRecord(input: {
  store: any;
  record: AppStoreAccountRecord;
  userID: string;
  tombstoneUserID: string;
  now: Date;
}) {
  const recordID = clean(input.record.id);
  const lastUsedAt = clean(input.record.last_used_at);
  if (!recordID || !lastUsedAt) {
    throw new AppleAccountReservationError(
      "incomplete_binding",
      "A newly reserved Apple account row is incomplete.",
    );
  }
  try {
    const result = await input.store.updateMany(
      {
        id: recordID,
        user_id: input.userID,
        last_used_at: lastUsedAt,
      },
      {
        $set: {
          user_id: input.tombstoneUserID,
          last_used_at: input.now.toISOString(),
        },
      },
    );
    if (Number(result?.updated) === 1) return;
  } catch {
    // A lost response may still have applied the redaction. Verify below.
  }
  if (
    await isSafelyRedactedOrDeletionLeased({
      store: input.store,
      recordID,
      userID: input.userID,
      tombstoneUserID: input.tombstoneUserID,
      now: input.now,
    })
  ) return;
  throw new AppleAccountReservationError(
    "cas_contention",
    "Apple account deletion changed during purchase preparation.",
  );
}

async function blockForAccountDeletion(input: {
  store: any;
  unhandedRecords: readonly AppStoreAccountRecord[];
  userID: string;
  tombstoneUserID: string;
  now: Date;
}): Promise<never> {
  const unique = new Map<string, AppStoreAccountRecord>();
  for (const record of input.unhandedRecords) {
    const recordID = clean(record.id);
    if (recordID) unique.set(recordID, record);
  }
  for (const record of unique.values()) {
    await redactUnhandedRecord({ ...input, record });
  }
  throw new AppleAccountReservationError(
    "deletion_in_progress",
    "Account deletion is in progress. Retry after it finishes.",
  );
}

/**
 * Reserves a stable StoreKit appAccountToken while joining deleteAccount's
 * live-user sentinel and deterministic tombstone marker.
 *
 * New rows are created under the one-way tombstone in a durable `pending`
 * state, never under the raw user id. Only after another marker check does a
 * CAS claim the pending row for the live user while atomically taking a future
 * lease on that same row. deleteAccount must acquire every such row before any
 * destructive cleanup, so a lost response or worker crash can leave raw
 * identity only behind a lease that deletion cannot cross.
 */
export async function reserveAppleAccountToken(
  store: any,
  userIDValue: unknown,
  nowFactory: () => Date = () => new Date(),
  randomUUID: () => string = () => crypto.randomUUID(),
): Promise<string> {
  const userID = clean(userIDValue);
  if (!userID) {
    throw new AppleAccountReservationError(
      "incomplete_binding",
      "A user id is required to reserve an Apple account token.",
    );
  }
  const tombstoneUserID = await deletedAccountTombstone(userID);

  for (let attempt = 0; attempt < RESERVATION_ATTEMPTS; attempt += 1) {
    const now = nowFactory();
    const [liveRecords, tombstoneRecords] = await Promise.all([
      allMatchingRecords<AppStoreAccountRecord>(store, { user_id: userID }),
      allMatchingRecords<AppStoreAccountRecord>(store, {
        user_id: tombstoneUserID,
      }),
    ]);
    const pendingRecords = tombstoneRecords.filter((record) =>
      clean(record.reservation_state) === PENDING_RESERVATION_STATE
    );
    const deletionMarkers = tombstoneRecords.filter((record) =>
      clean(record.reservation_state) !== PENDING_RESERVATION_STATE
    );
    if (deletionMarkers.length) {
      return await blockForAccountDeletion({
        store,
        unhandedRecords: [],
        userID,
        tombstoneUserID,
        now,
      });
    }

    const canonical = canonicalAppleAccountRecord(liveRecords);
    if (canonical?.id && canonical.app_account_token) {
      const observedLastUsedAt = clean(canonical.last_used_at);
      if (!observedLastUsedAt) {
        throw new AppleAccountReservationError(
          "incomplete_binding",
          "Apple account binding is incomplete.",
        );
      }
      if (isAppleAccountLeaseActive(observedLastUsedAt, now)) {
        throw new AppleAccountReservationError(
          "active_lease",
          "Apple account binding is being updated. Retry shortly.",
        );
      }

      const leaseUntil = reservationLeaseUntil(now, observedLastUsedAt);
      let result: any;
      try {
        result = await store.updateMany(
          {
            id: canonical.id,
            user_id: userID,
            last_used_at: observedLastUsedAt,
          },
          {
            $set: {
              reservation_state: ACTIVE_RESERVATION_STATE,
              last_used_at: leaseUntil,
            },
          },
        );
      } catch {
        try {
          if (
            await hasExactReservationLease({
              store,
              recordID: canonical.id,
              userID,
              leaseUntil,
            })
          ) {
            result = { updated: 1 };
          }
        } catch {
          // Unknown acquisition remains fail-closed. If the CAS applied, its
          // future lease prevents deleteAccount from crossing this raw row.
        }
        if (Number(result?.updated) !== 1) {
          throw new AppleAccountReservationError(
            "cas_contention",
            "Apple account reservation lease could not be reconciled.",
          );
        }
      }
      if (Number(result?.updated) !== 1) continue;

      const leasedRecord = {
        ...canonical,
        reservation_state: ACTIVE_RESERVATION_STATE,
        last_used_at: leaseUntil,
      };
      const postCommitTombstones = await allMatchingRecords<
        AppStoreAccountRecord
      >(store, { user_id: tombstoneUserID });
      const postCommitMarkers = postCommitTombstones.filter((record) =>
        clean(record.reservation_state) !== PENDING_RESERVATION_STATE
      );
      if (postCommitMarkers.length) {
        return await blockForAccountDeletion({
          store,
          unhandedRecords: [leasedRecord],
          userID,
          tombstoneUserID,
          now: nowFactory(),
        });
      }
      await releaseReservationLease({
        store,
        recordID: clean(canonical.id),
        userID,
        leaseUntil,
        releasedAt: nowFactory().toISOString(),
      });
      return canonicalUUID(canonical.app_account_token);
    }

    const pending = canonicalAppleAccountRecord(pendingRecords);
    if (pending?.id && pending.app_account_token) {
      const observedLastUsedAt = clean(pending.last_used_at);
      if (!observedLastUsedAt) {
        throw new AppleAccountReservationError(
          "incomplete_binding",
          "Pending Apple account reservation is incomplete.",
        );
      }
      if (isAppleAccountLeaseActive(observedLastUsedAt, now)) {
        throw new AppleAccountReservationError(
          "active_lease",
          "Apple account binding is being updated. Retry shortly.",
        );
      }
      const leaseUntil = reservationLeaseUntil(now, observedLastUsedAt);
      let claim: any;
      try {
        claim = await store.updateMany(
          {
            id: pending.id,
            user_id: tombstoneUserID,
            reservation_state: PENDING_RESERVATION_STATE,
            last_used_at: observedLastUsedAt,
          },
          {
            $set: {
              user_id: userID,
              reservation_state: ACTIVE_RESERVATION_STATE,
              last_used_at: leaseUntil,
            },
          },
        );
      } catch {
        try {
          if (
            await hasExactReservationLease({
              store,
              recordID: pending.id,
              userID,
              leaseUntil,
            })
          ) {
            claim = { updated: 1 };
          }
        } catch {
          // Unknown claim remains fail-closed. The only raw state this CAS can
          // produce carries the future lease in the same atomic update.
        }
        if (Number(claim?.updated) !== 1) {
          throw new AppleAccountReservationError(
            "cas_contention",
            "Pending Apple reservation claim could not be reconciled.",
          );
        }
      }
      if (Number(claim?.updated) !== 1) continue;

      const claimedRecord: AppStoreAccountRecord = {
        ...pending,
        user_id: userID,
        reservation_state: ACTIVE_RESERVATION_STATE,
        last_used_at: leaseUntil,
      };
      const postClaimTombstones = await allMatchingRecords<
        AppStoreAccountRecord
      >(store, { user_id: tombstoneUserID });
      const postClaimMarkers = postClaimTombstones.filter((record) =>
        clean(record.reservation_state) !== PENDING_RESERVATION_STATE
      );
      if (postClaimMarkers.length) {
        return await blockForAccountDeletion({
          store,
          unhandedRecords: [claimedRecord],
          userID,
          tombstoneUserID,
          now: nowFactory(),
        });
      }
      await releaseReservationLease({
        store,
        recordID: clean(pending.id),
        userID,
        leaseUntil,
        releasedAt: nowFactory().toISOString(),
      });
      return canonicalUUID(pending.app_account_token);
    }

    const createdAt = now.toISOString();
    const pendingToken = canonicalUUID(randomUUID());
    let created: AppStoreAccountRecord;
    try {
      created = await store.create({
        user_id: tombstoneUserID,
        app_account_token: pendingToken,
        reservation_state: PENDING_RESERVATION_STATE,
        created_at: createdAt,
        last_used_at: createdAt,
      });
    } catch {
      const reconciled = await allMatchingRecords<AppStoreAccountRecord>(
        store,
        {
          user_id: tombstoneUserID,
          app_account_token: pendingToken,
          reservation_state: PENDING_RESERVATION_STATE,
        },
      );
      if (reconciled.length === 1) continue;
      throw new AppleAccountReservationError(
        "cas_contention",
        "Pending Apple reservation creation could not be reconciled.",
      );
    }
    const createdID = clean(created?.id);
    if (!createdID) {
      throw new AppleAccountReservationError(
        "incomplete_binding",
        "The Apple account reservation is missing its entity id.",
      );
    }
  }

  throw new AppleAccountReservationError(
    "cas_contention",
    "Apple account binding changed concurrently. Retry shortly.",
  );
}
