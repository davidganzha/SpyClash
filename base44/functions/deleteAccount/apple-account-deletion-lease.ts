import {
  type AppleAccountLeaseCandidate,
  canonicalAppleAccountRecord,
  isAppleAccountLeaseActive,
} from "../app-store-entitlement/apple-account-binding.ts";

const ENTITY_PAGE_SIZE = 100;

// Keep this identical to the lease used by app-store-entitlement. Both
// functions coordinate through the canonical AppStoreAccount row itself.
export const APPLE_ACCOUNT_DELETION_LEASE_MILLISECONDS = 5 * 60 * 1_000;

export type AppleAccountDeletionRecord = AppleAccountLeaseCandidate & {
  app_account_token?: string;
};

export type AppleAccountDeletionLease = {
  appAccountToken: string;
  accountID: string;
  ownerUserID: string;
  observedLastUsedAt: string;
  leaseUntil: string;
  accounts: AppleAccountDeletionRecord[];
};

export type AppleAccountDeletionLeaseErrorCode =
  | "incomplete_binding"
  | "mixed_owners"
  | "active_lease"
  | "cas_contention"
  | "lease_release_failed"
  | "lease_commit_failed";

export class AppleAccountDeletionLeaseError extends Error {
  readonly code: AppleAccountDeletionLeaseErrorCode;

  constructor(code: AppleAccountDeletionLeaseErrorCode, message: string) {
    super(message);
    this.name = "AppleAccountDeletionLeaseError";
    this.code = code;
  }
}

function clean(value: unknown): string {
  return String(value ?? "").trim();
}

function canonicalToken(value: unknown): string {
  const token = clean(value).toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(token)
  ) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "An App Store account binding has an invalid account token.",
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

function requireOwnedTokenRecords(
  records: readonly AppleAccountDeletionRecord[],
  appAccountToken: string,
  userID: string,
): AppleAccountDeletionRecord[] {
  if (records.length === 0) {
    throw new AppleAccountDeletionLeaseError(
      "cas_contention",
      "The App Store account binding changed concurrently.",
    );
  }

  for (const record of records) {
    if (canonicalToken(record.app_account_token) !== appAccountToken) {
      throw new AppleAccountDeletionLeaseError(
        "incomplete_binding",
        "An App Store account binding has inconsistent account tokens.",
      );
    }
    if (clean(record.user_id) !== userID) {
      throw new AppleAccountDeletionLeaseError(
        "mixed_owners",
        "An App Store account token is linked to multiple account owners.",
      );
    }
  }
  return [...records];
}

async function releaseAcquiredLeasesBestEffort(
  store: any,
  leases: readonly AppleAccountDeletionLease[],
  now: Date,
) {
  for (const lease of [...leases].reverse()) {
    try {
      await store.updateMany(
        {
          id: lease.accountID,
          user_id: lease.ownerUserID,
          last_used_at: lease.leaseUntil,
        },
        { $set: { last_used_at: now.toISOString() } },
      );
    } catch {
      // The original acquisition error is more useful to the caller. A later
      // request can safely recover once the bounded lease expires.
    }
  }
}

/**
 * Acquires the same deterministic canonical-row CAS lease used by
 * app-store-entitlement for every durable Apple token owned by the user.
 *
 * Acquiring tokens in lexical order makes multi-token deletion deterministic.
 * If any token is busy or changes concurrently, all leases acquired by this
 * call are released before the error is returned.
 */
export async function acquireAppleAccountDeletionLeases(
  store: any,
  userIDValue: unknown,
  now = new Date(),
): Promise<AppleAccountDeletionLease[]> {
  const userID = clean(userIDValue);
  if (!userID) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "A user id is required to lease App Store account bindings.",
    );
  }

  const initiallyOwned = await allMatchingRecords<AppleAccountDeletionRecord>(
    store,
    { user_id: userID },
  );
  const tokens = [
    ...new Set(
      initiallyOwned.map((record) => canonicalToken(record.app_account_token)),
    ),
  ].sort();
  if (tokens.length === 0) return [];

  const leaseUntil = new Date(
    now.getTime() + APPLE_ACCOUNT_DELETION_LEASE_MILLISECONDS,
  ).toISOString();
  const acquired: AppleAccountDeletionLease[] = [];

  try {
    for (const appAccountToken of tokens) {
      const accounts = requireOwnedTokenRecords(
        await allMatchingRecords<AppleAccountDeletionRecord>(store, {
          app_account_token: appAccountToken,
        }),
        appAccountToken,
        userID,
      );
      const canonical = canonicalAppleAccountRecord(accounts);
      const accountID = clean(canonical?.id);
      const observedLastUsedAt = clean(canonical?.last_used_at);
      if (!accountID || !observedLastUsedAt) {
        throw new AppleAccountDeletionLeaseError(
          "incomplete_binding",
          "The canonical App Store account binding is incomplete.",
        );
      }
      if (isAppleAccountLeaseActive(observedLastUsedAt, now)) {
        throw new AppleAccountDeletionLeaseError(
          "active_lease",
          "The App Store account binding is being updated.",
        );
      }

      const result = await store.updateMany(
        {
          id: accountID,
          user_id: userID,
          last_used_at: observedLastUsedAt,
        },
        { $set: { last_used_at: leaseUntil } },
      );
      if (Number(result?.updated) !== 1) {
        throw new AppleAccountDeletionLeaseError(
          "cas_contention",
          "The App Store account binding changed concurrently.",
        );
      }

      acquired.push({
        appAccountToken,
        accountID,
        ownerUserID: userID,
        observedLastUsedAt,
        leaseUntil,
        accounts: accounts.map((account) =>
          account.id === accountID
            ? { ...account, last_used_at: leaseUntil }
            : account
        ),
      });
    }

    // Close the discovery/acquisition window before billing redaction starts.
    // Every correctly behaved Apple writer now sees an active canonical lease.
    const currentlyOwned = await allMatchingRecords<AppleAccountDeletionRecord>(
      store,
      { user_id: userID },
    );
    const currentTokens = [
      ...new Set(
        currentlyOwned.map((record) =>
          canonicalToken(record.app_account_token)
        ),
      ),
    ].sort();
    if (currentTokens.join("\n") !== tokens.join("\n")) {
      throw new AppleAccountDeletionLeaseError(
        "cas_contention",
        "The user's App Store account tokens changed during deletion.",
      );
    }

    for (const lease of acquired) {
      const accounts = requireOwnedTokenRecords(
        await allMatchingRecords<AppleAccountDeletionRecord>(store, {
          app_account_token: lease.appAccountToken,
        }),
        lease.appAccountToken,
        userID,
      );
      const canonical = canonicalAppleAccountRecord(accounts);
      if (
        clean(canonical?.id) !== lease.accountID ||
        clean(canonical?.user_id) !== userID ||
        clean(canonical?.last_used_at) !== lease.leaseUntil
      ) {
        throw new AppleAccountDeletionLeaseError(
          "cas_contention",
          "The canonical App Store account binding changed during deletion.",
        );
      }
    }

    return acquired;
  } catch (error) {
    await releaseAcquiredLeasesBestEffort(store, acquired, now);
    throw error;
  }
}

/** Releases every canonical lease without changing account ownership. */
export async function releaseAppleAccountDeletionLeases(
  store: any,
  leases: readonly AppleAccountDeletionLease[],
  now = new Date(),
): Promise<void> {
  const failures: string[] = [];
  for (const lease of [...leases].reverse()) {
    try {
      const result = await store.updateMany(
        {
          id: lease.accountID,
          user_id: lease.ownerUserID,
          last_used_at: lease.leaseUntil,
        },
        { $set: { last_used_at: now.toISOString() } },
      );
      if (Number(result?.updated) !== 1) failures.push(lease.accountID);
    } catch {
      failures.push(lease.accountID);
    }
  }
  if (failures.length) {
    throw new AppleAccountDeletionLeaseError(
      "lease_release_failed",
      `Failed to release App Store account leases: ${failures.join(", ")}`,
    );
  }
}

/**
 * Commits deletion by atomically replacing the owner and releasing each
 * canonical lease. This must run only after User.delete succeeds.
 */
export async function commitAppleAccountDeletionLeases(
  store: any,
  leases: readonly AppleAccountDeletionLease[],
  tombstoneUserIDValue: unknown,
  now = new Date(),
): Promise<void> {
  const tombstoneUserID = clean(tombstoneUserIDValue);
  if (!/^deleted:[0-9a-f]{40}$/.test(tombstoneUserID)) {
    throw new AppleAccountDeletionLeaseError(
      "incomplete_binding",
      "A valid deleted-account tombstone is required.",
    );
  }

  const failures: string[] = [];
  for (const lease of leases) {
    try {
      const result = await store.updateMany(
        {
          id: lease.accountID,
          user_id: lease.ownerUserID,
          last_used_at: lease.leaseUntil,
        },
        {
          $set: {
            user_id: tombstoneUserID,
            last_used_at: now.toISOString(),
          },
        },
      );
      if (Number(result?.updated) !== 1) failures.push(lease.accountID);
    } catch {
      failures.push(lease.accountID);
    }
  }
  if (failures.length) {
    throw new AppleAccountDeletionLeaseError(
      "lease_commit_failed",
      `Failed to commit App Store account deletion: ${failures.join(", ")}`,
    );
  }
}

export function leasedCanonicalAppleAccountIDs(
  leases: readonly AppleAccountDeletionLease[],
): ReadonlySet<string> {
  return new Set(leases.map((lease) => lease.accountID));
}
